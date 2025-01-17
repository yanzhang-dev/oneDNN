/*******************************************************************************
* Copyright 2021-2022 Arm Ltd. and affiliates
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*******************************************************************************/

#ifndef CPU_AARCH64_ACL_INDIRECT_GEMM_CONVOLUTION_HPP
#define CPU_AARCH64_ACL_INDIRECT_GEMM_CONVOLUTION_HPP

#include "cpu/cpu_convolution_pd.hpp"

#include "cpu/aarch64/acl_convolution_utils.hpp"

namespace dnnl {
namespace impl {
namespace cpu {
namespace aarch64 {

struct acl_indirect_gemm_resource_t : public resource_t {
    acl_indirect_gemm_resource_t()
        : acl_obj_(utils::make_unique<acl_obj_t<arm_compute::NEGEMMConv2d>>()) {
    }

    status_t configure(const acl_conv_conf_t &acp) {
        if (!acl_obj_) return status::out_of_memory;

        // Init Compute Library tensors based on info from descriptor
        acl_obj_->src_tensor.allocator()->init(acp.src_info);
        acl_obj_->wei_tensor.allocator()->init(acp.wei_info);
        acl_obj_->dst_tensor.allocator()->init(acp.dst_info);
        acl_obj_->bia_tensor.allocator()->init(acp.bia_info);
        if (acp.sum_with_eltwise) {
            acl_obj_->dst_acc_tensor.allocator()->init(acp.dst_info);
        }
        // clang-format off
        acl_obj_->conv.configure(
            &acl_obj_->src_tensor,
            &acl_obj_->wei_tensor,
            acp.with_bias ? &acl_obj_->bia_tensor : nullptr,
            acp.sum_with_eltwise ? &acl_obj_->dst_acc_tensor
                                 : &acl_obj_->dst_tensor,
            arm_compute::Conv2dInfo(acp.padstride_info,
                                    acp.dilation_info,
                                    acp.sum_with_eltwise
                                        ? arm_compute::ActivationLayerInfo()
                                        : acp.act_info,
                                    acp.fast_math,
                                    1));
        // clang-format on
        if (acp.sum_with_eltwise) {
            acl_obj_->add.configure(&acl_obj_->dst_tensor,
                    &acl_obj_->dst_acc_tensor, &acl_obj_->dst_acc_tensor,
                    arm_compute::ConvertPolicy::SATURATE);
            acl_obj_->act.configure(&acl_obj_->dst_acc_tensor,
                    &acl_obj_->dst_tensor, acp.act_info);
            acl_obj_->dst_acc_tensor.allocator()->allocate();
        }

        return status::success;
    }

    acl_obj_t<arm_compute::NEGEMMConv2d> &get_acl_obj() const {
        return *acl_obj_;
    }

    DNNL_DISALLOW_COPY_AND_ASSIGN(acl_indirect_gemm_resource_t);

private:
    std::unique_ptr<acl_obj_t<arm_compute::NEGEMMConv2d>> acl_obj_;

}; // acl_indirect_gemm_resource_t

struct acl_indirect_gemm_convolution_fwd_t : public primitive_t {

    struct pd_t : public cpu_convolution_fwd_pd_t {
        pd_t(const convolution_desc_t *adesc, const primitive_attr_t *attr,
                const typename pd_t::base_class *hint_fwd_pd)
            : cpu_convolution_fwd_pd_t(adesc, attr, hint_fwd_pd), acp_() {}

        DECLARE_COMMON_PD_T("indirect_gemm:acl",
                acl_indirect_gemm_convolution_fwd_t, USE_GLOBAL_SCRATCHPAD);

        status_t init(engine_t *engine) {
            using namespace data_type;
            using smask_t = primitive_attr_t::skip_mask_t;

            bool ok = is_fwd()
                    && set_default_alg_kind(alg_kind::convolution_direct)
                    && expect_data_types(data_type::f32, data_type::f32,
                            data_type::f32, data_type::f32, undef)
                    && !has_zero_dim_memory()
                    && attr()->has_default_values(
                            smask_t::post_ops, data_type::f32)
                    && post_ops_ok();
            if (!ok) return status::unimplemented;

            auto conf_status = acl_convolution_utils::init_conf_indirect_gemm(
                    acp_, src_md_, weights_md_, dst_md_, bias_md_, *desc(),
                    *attr());
            if (conf_status != status::success) return status::unimplemented;

            return status::success;
        }

        acl_conv_conf_t acp_;

    protected:
        bool post_ops_ok() const {
            using namespace data_type;
            using namespace alg_kind;
            auto const &po = attr()->post_ops_;
            // "true" here stands for eltwise.scale == 1.f check
            auto is_eltwise
                    = [&](int idx) { return po.entry_[idx].is_eltwise(true); };
            auto is_sum = [&](int idx) { return po.entry_[idx].is_sum(); };

            bool sum_with_eltwise
                    = (po.len() == 2) && is_sum(0) && is_eltwise(1);
            bool eltwise_only = (po.len() == 1) ? is_eltwise(0) : false;
            bool eltwise_ok = false;
            // Compute Library supports only one eltwise post-op or
            // sum+eltwise post-ops
            if (eltwise_only || sum_with_eltwise) {
                const auto act_type = po.entry_[sum_with_eltwise].eltwise.alg;
                eltwise_ok = acl_utils::acl_act_ok(act_type);
            }

            return eltwise_ok || (po.len() == 0);
        }
    };

    acl_indirect_gemm_convolution_fwd_t(const pd_t *apd) : primitive_t(apd) {}

    status_t create_resource(
            engine_t *engine, resource_mapper_t &mapper) const override {
        if (mapper.has_resource(this)) return status::success;

        auto r = utils::make_unique<acl_indirect_gemm_resource_t>();
        if (!r) return status::out_of_memory;

        // Configure the resource based on information from primitive descriptor
        auto st = r->configure(pd()->acp_);
        if (st == status::success) { mapper.add(this, std::move(r)); }

        return st;
    }

    typedef typename prec_traits<data_type::f32>::type data_t;

    status_t execute(const exec_ctx_t &ctx) const override {
        return execute_forward(ctx);
    }

private:
    // To guard the const execute_forward(), the mutex must be 'mutable'
    mutable std::mutex mtx;
    status_t execute_forward(const exec_ctx_t &ctx) const;
    const pd_t *pd() const { return (const pd_t *)primitive_t::pd().get(); }
};

} // namespace aarch64
} // namespace cpu
} // namespace impl
} // namespace dnnl

#endif // CPU_AARCH64_ACL_INDIRECT_GEMM_CONVOLUTION_HPP

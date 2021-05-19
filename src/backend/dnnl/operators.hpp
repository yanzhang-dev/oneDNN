/*******************************************************************************
* Copyright 2020-2021 Intel Corporation
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

#ifndef BACKEND_DNNL_OPERATORS_HPP
#define BACKEND_DNNL_OPERATORS_HPP

#include "operators/batchnorm.hpp"
#include "operators/binary.hpp"
#include "operators/conv.hpp"
#include "operators/eltwise.hpp"
#include "operators/inner_product.hpp"
#include "operators/layernorm.hpp"
#include "operators/logsoftmax.hpp"
#include "operators/matmul.hpp"
#include "operators/pool.hpp"
#include "operators/quantize.hpp"
#include "operators/reorder.hpp"
#include "operators/softmax.hpp"

#include "subgraph/operators/int8_conv.hpp"
#include "subgraph/operators/int8_matmul.hpp"

#endif
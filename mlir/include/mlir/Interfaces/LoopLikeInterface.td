//===- LoopLikeInterface.td - LoopLike interface -----------*- tablegen -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Defines the interface for loop-like operations.
//
//===----------------------------------------------------------------------===//

#ifndef MLIR_INTERFACES_LOOPLIKEINTERFACE
#define MLIR_INTERFACES_LOOPLIKEINTERFACE

include "mlir/IR/OpBase.td"

def LoopLikeOpInterface : OpInterface<"LoopLikeOpInterface"> {
  let description = [{
    Encodes properties of a loop. Operations that implement this interface will
    be considered by loop-invariant code motion.
  }];
  let cppNamespace = "::mlir";

  let methods = [
    InterfaceMethod<[{
        Returns true if the given value is defined outside of the loop.
        A sensible implementation could be to check whether the value's defining
        operation lies outside of the loops body region. If the loop uses
        explicit capture of dependencies, an implementation could check whether
        the value corresponds to a captured dependency.
      }],
      "bool", "isDefinedOutsideOfLoop", (ins "::mlir::Value ":$value)
    >,
    InterfaceMethod<[{
        Returns the region that makes up the body of the loop and should be
        inspected for loop-invariant operations.
      }],
      "::mlir::Region &", "getLoopBody"
    >,
    InterfaceMethod<[{
        Moves the given vector of operations out of the loop. The vector is
        sorted topologically.
      }],
      "::mlir::LogicalResult", "moveOutOfLoop", (ins "::mlir::ArrayRef<::mlir::Operation *>":$ops)
    >,
    InterfaceMethod<[{
        If there is a single induction variable return it, otherwise return
        llvm::None.
      }],
      /*retTy=*/"::mlir::Optional<::mlir::Value>",
      /*methodName=*/"getSingleInductionVar",
      /*args=*/(ins),
      /*methodBody=*/"",
      /*defaultImplementation=*/[{
        return llvm::None;
      }]
    >,
    InterfaceMethod<[{
        Return the single lower bound value or attribute if it exist, otherwise
        return llvm::None.
      }],
      /*retTy=*/"::mlir::Optional<::mlir::OpFoldResult>",
      /*methodName=*/"getSingleLowerBound",
      /*args=*/(ins),
      /*methodBody=*/"",
      /*defaultImplementation=*/[{
        return llvm::None;
      }]
    >,
    InterfaceMethod<[{
        Return the single step value or attribute if it exist, otherwise
        return llvm::None.
      }],
      /*retTy=*/"::mlir::Optional<::mlir::OpFoldResult>",
      /*methodName=*/"getSingleStep",
      /*args=*/(ins),
      /*methodBody=*/"",
      /*defaultImplementation=*/[{
        return llvm::None;
      }]
    >,
  ];
}

#endif // MLIR_INTERFACES_LOOPLIKEINTERFACE

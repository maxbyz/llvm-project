//===- LinalgStructuredOps.td - Linalg dialect library ops -*- tablegen -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This is the operation definition file for structured operations on buffers
// that correspond to underlying library calls (e.g. BLAS).
//
//===----------------------------------------------------------------------===//

#ifndef LINALG_STRUCTURED_OPS
#define LINALG_STRUCTURED_OPS

include "mlir/Dialect/Linalg/IR/LinalgBase.td"
include "mlir/Dialect/Linalg/IR/LinalgInterfaces.td"
include "mlir/Interfaces/InferTypeOpInterface.td"
include "mlir/Interfaces/SideEffectInterfaces.td"

// Base Tablegen class for Linalg ops.
// Linalg ops that correspond to library calls operate on ShapedType as their
// first operands. These may be optionally followed by non-view operands
// depending on the specific Linalg op.
class LinalgStructuredBase_Op<string mnemonic, list<Trait> props>
  : Op<Linalg_Dialect, mnemonic, !listconcat([
       SingleBlockImplicitTerminator<"YieldOp">,
       DeclareOpInterfaceMethods<MemoryEffectsOpInterface>,
       LinalgStructuredInterface,
       ReifyRankedShapedTypeOpInterface], props)> {
  code structuredOpsBaseDecls = [{
    // Return whether the op accesses the iteration indices.
    bool hasIndexSemantics() {
      return !this->getBody()->getOps<IndexOp>().empty();
    }

    LogicalResult reifyResultShapes(OpBuilder &b,
        ReifiedRankedShapedTypeDims &reifiedReturnShapes) {
      return llvm::cast<LinalgOp>(getOperation()).reifyResultShapes(b,
          reifiedReturnShapes);
    }
  }];
}

class LinalgStructured_Op<string mnemonic, list<Trait> props>
  : LinalgStructuredBase_Op<mnemonic, !listconcat(props, [])> {
  code structuredOpsDecls = structuredOpsBaseDecls # [{
    std::string getLibraryCallName() {
      return generateLibraryCallName(getOperation());
    }
  }];
  let assemblyFormat = "`(` operands `)` attr-dict `:` type(operands)";
}

//===----------------------------------------------------------------------===//
// Named Linalg ops, implemented as special configurations of generic ops.
//===----------------------------------------------------------------------===//

def FillOp : LinalgStructured_Op<"fill", []> {
  let arguments = (ins
    AnyTypeOf<[AnyComplex, AnyFloat, AnySignlessInteger, AnyVector]>:$value,
    AnyShaped:$output);
  let results = (outs Optional<AnyRankedTensor>:$result);
  let regions = (region AnyRegion:$region);
  let extraClassDeclaration = structuredOpsDecls # [{
    ValueRange inputs() { return getOperands().take_front(); }
    ValueRange outputs() { return getOperands().take_back(); }

    // Rank-polymorphic.
    //   filling_value -> O(ivs) with parallel iterators.
    ArrayAttr iterator_types() {
      int64_t nPar = getRank(getOutputOperand(0));
      return Builder(getContext()).getStrArrayAttr(
        SmallVector<StringRef, 8>(nPar, getParallelIteratorTypeName()));
    }

    ArrayAttr indexing_maps() {
      MLIRContext *context = getContext();
      // filling_value -> O(ivs)
      return Builder(getContext()).getAffineMapArrayAttr({
          AffineMap::get(getNumParallelLoops(), 0, {}, getContext()),
          extractOrIdentityMap(llvm::None, getNumParallelLoops(), context)});
    }

    static void regionBuilder(ImplicitLocOpBuilder &b, Block &block,
                              ArrayRef<NamedAttribute> attrs);
    static std::function<void(ImplicitLocOpBuilder&,
                              Block&, ArrayRef<NamedAttribute>)>
    getRegionBuilder() {
      return &regionBuilder;
    }
    static unsigned getNumRegionArgs() { return 2; }
  }];

  let assemblyFormat = [{
    `(` $value `,` $output `)` attr-dict `:`
        type($value) `,` type($output) (`->` type($result)^)?
      custom<FillOpRegion>($region, ref(type($value)), ref(type($output)))
  }];

  let builders = [
    OpBuilder<(ins "Value":$value, "Value":$output)>
  ];

  let hasFolder = 1;
  let hasCanonicalizer = 1;
  let hasVerifier = 1;
}

//===----------------------------------------------------------------------===//
// Generic Linalg ops.
//===----------------------------------------------------------------------===//

def GenericOp : LinalgStructuredBase_Op<"generic", [AttrSizedOperandSegments]> {
  let description = [{
    Generic Linalg op form where the key properties of the computation are
    specified as attributes. In pretty form, a `linalg.generic` op is written
    as:

      ```mlir
      linalg.generic #trait_attribute
          ins(%A, %B : memref<?x?xf32, stride_specification>,
                       memref<?x?xf32, stride_specification>)
          outs(%C : memref<?x?xf32, stride_specification>)
          attrs = {other-optional-attributes}
          {region}
      ```

    Where #trait_attributes is an alias of a dictionary attribute containing:
      - doc [optional]: a documentation string
      - indexing_maps: a list of AffineMapAttr, one AffineMapAttr per each input
        and output view. Such AffineMapAttr specifies the mapping between the
        loops and the indexing within each view.
      - library_call [optional]: a StringAttr containing the name of an
        external library function that the linalg.generic operation maps to.
        The external library is assumed to be dynamically linked and no strong
        compile-time guarantees are provided. In the absence of such a library
        call, linalg.generic will always lower to loops.
      - iterator_types: an ArrayAttr specifying the type of the enclosing loops.
        Each element of the list represents and iterator of one of the following
        types:
          parallel, reduction, window

    Example:
    Defining a #matmul_trait attribute in MLIR can be done as follows:
      ```mlir
      #matmul_accesses = [
        (m, n, k) -> (m, k),
        (m, n, k) -> (k, n),
        (m, n, k) -> (m, n)
      ]
      #matmul_trait = {
        doc = "C(m, n) += A(m, k) * B(k, n)",
        indexing_maps = #matmul_accesses,
        library_call = "linalg_matmul",
        iterator_types = ["parallel", "parallel", "reduction"]
      }
      ```

    And can be reused in multiple places as:
      ```mlir
      linalg.generic #matmul_trait
        ins(%A, %B : memref<?x?xf32, stride_specification>,
                     memref<?x?xf32, stride_specification>)
        outs(%C : memref<?x?xf32, stride_specification>)
        {other-optional-attributes} {
        ^bb0(%a: f32, %b: f32, %c: f32) :
          %d = arith.mulf %a, %b: f32
          %e = arith.addf %c, %d: f32
          linalg.yield %e : f32
      }
      ```

    This may lower to either:
      ```mlir
      call @linalg_matmul(%A, %B, %C) :
        (memref<?x?xf32, stride_specification>,
         memref<?x?xf32, stride_specification>,
         memref<?x?xf32, stride_specification>)
        -> ()
      ```

    or IR resembling:
    ```mlir
    scf.for %m = %c0 to %M step %c1 {
      scf.for %n = %c0 to %N step %c1 {
        scf.for %k = %c0 to %K step %c1 {
          %a = load %A[%m, %k] : memref<?x?xf32, stride_specification>
          %b = load %B[%k, %n] : memref<?x?xf32, stride_specification>
          %c = load %C[%m, %n] : memref<?x?xf32, stride_specification>
          %d = arith.mulf %a, %b: f32
          %e = arith.addf %c, %d: f32
          store %e, %C[%m, %n] : memref<?x?x?xf32, stride_specification>
        }
      }
    }
    ```

    To allow progressive lowering from the value world (a.k.a tensor values) to
    the buffer world (a.k.a memref values), a `linalg.generic` op allows mixing
    tensors and buffers operands and tensor results.

    ```mlir
    %C = linalg.generic #trait_attribute
      ins(%A, %B : tensor<?x?xf32>, memref<?x?xf32, stride_specification>)
      outs(%C : tensor<?x?xf32>)
      {other-optional-attributes}
      {region}
      -> (tensor<?x?xf32>)
    ```
  }];

  let arguments = (ins Variadic<AnyType>:$inputs,
                       Variadic<AnyShaped>:$outputs,
                       AffineMapArrayAttr:$indexing_maps,
                       ArrayAttr:$iterator_types,
                       OptionalAttr<StrAttr>:$doc,
                       OptionalAttr<StrAttr>:$library_call);
  let results = (outs Variadic<AnyRankedTensor>:$result_tensors);
  let regions = (region AnyRegion:$region);

  let builders = [
    OpBuilder<(ins "TypeRange":$resultTensorTypes, "ValueRange":$inputs,
      "ValueRange":$outputs, "ArrayRef<AffineMap>":$indexingMaps,
      "ArrayRef<StringRef>":$iteratorTypes, "StringRef":$doc,
      "StringRef":$libraryCall,
      CArg<"function_ref<void(OpBuilder &, Location, ValueRange)>", "nullptr">,
      CArg<"ArrayRef<NamedAttribute>", "{}">:$attributes)>,
    OpBuilder<(ins "ValueRange":$inputs, "ValueRange":$outputBuffers,
      "ArrayRef<AffineMap>":$indexingMaps, "ArrayRef<StringRef>":$iteratorTypes,
      "StringRef":$doc, "StringRef":$libraryCall,
      CArg<"function_ref<void(OpBuilder &, Location, ValueRange)>", "nullptr">,
      CArg<"ArrayRef<NamedAttribute>", "{}">:$attributes)>,
    OpBuilder<(ins "TypeRange":$resultTensorTypes, "ValueRange":$inputs,
      "ValueRange":$outputs, "ArrayRef<AffineMap>":$indexingMaps,
      "ArrayRef<StringRef>":$iteratorTypes,
      CArg<"function_ref<void(OpBuilder &, Location, ValueRange)>", "nullptr">,
      CArg<"ArrayRef<NamedAttribute>", "{}">:$attributes)>,
    OpBuilder<(ins "ValueRange":$inputs, "ValueRange":$outputBuffers,
      "ArrayRef<AffineMap>":$indexingMaps, "ArrayRef<StringRef>":$iteratorTypes,
      CArg<"function_ref<void(OpBuilder &, Location, ValueRange)>", "nullptr">,
      CArg<"ArrayRef<NamedAttribute>", "{}">:$attributes)>
  ];

  let extraClassDeclaration = structuredOpsBaseDecls # [{
    SmallVector<StringRef, 8> linalgTraitAttrNames() {
      return SmallVector<StringRef, 8>{
        getDocAttrName(),
        getIndexingMapsAttrName(), getLibraryCallAttrName(),
        getIteratorTypesAttrName(),
      };
    }
    std::string getLibraryCallName() {
      return library_call().hasValue() ?
        library_call()->str() : "op_has_no_registered_library_name";
    }

    static std::function<void(ImplicitLocOpBuilder &,
                              Block &, ArrayRef<NamedAttribute>)>
    getRegionBuilder() {
      return nullptr;
    }
  }];

  let hasCanonicalizer = 1;
  let hasCustomAssemblyFormat = 1;
  let hasFolder = 1;
  let hasVerifier = 1;
}


//===----------------------------------------------------------------------===//
// Named Linalg ops, implemented as a declarative configurations of generic ops.
//===----------------------------------------------------------------------===//

include "mlir/Dialect/Linalg/IR/LinalgNamedStructuredOps.yamlgen.td"

#endif // LINALG_STRUCTURED_OPS

//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

/// A type whose instances can be encoded, and appropriately passed, as
/// elements of a C `va_list`.
///
/// You use this protocol to present a native Swift interface to a C "varargs"
/// API. For example, a program can import a C API like the one defined here:
///
/// ~~~c
/// int c_api(int, va_list arguments)
/// ~~~
///
/// To create a wrapper for the `c_api` function, write a function that takes
/// `CVarArg` arguments, and then call the imported C function using the
/// `withVaList(_:_:)` function:
///
///     func swiftAPI(_ x: Int, arguments: CVarArg...) -> Int {
///         return withVaList(arguments) { c_api(x, $0) }
///     }
///
/// Swift only imports C variadic functions that use a `va_list` for their
/// arguments. C functions that use the `...` syntax for variadic arguments
/// are not imported, and therefore can't be called using `CVarArg` arguments.
///
/// If you need to pass an optional pointer as a `CVarArg` argument, use the
/// `Int(bitPattern:)` initializer to interpret the optional pointer as an
/// `Int` value, which has the same C variadic calling conventions as a pointer
/// on all supported platforms.
///
/// - Note: Declaring conformance to the `CVarArg` protocol for types defined
///   outside the standard library is not supported.
public protocol CVarArg {
  // Note: the protocol is public, but its requirement is stdlib-private.
  // That's because there are APIs operating on CVarArg instances, but
  // defining conformances to CVarArg outside of the standard library is
  // not supported.

  /// Transform `self` into a series of machine words that can be
  /// appropriately interpreted by C varargs.
  var _cVarArgEncoding: [Int] { get }
}

/// Floating point types need to be passed differently on x86_64
/// systems.  CoreGraphics uses this to make CGFloat work properly.
public // SPI(CoreGraphics)
protocol _CVarArgPassedAsDouble : CVarArg {}

/// Some types require alignment greater than Int on some architectures.
public // SPI(CoreGraphics)
protocol _CVarArgAligned : CVarArg {
  /// Returns the required alignment in bytes of
  /// the value returned by `_cVarArgEncoding`.
  var _cVarArgAlignment: Int { get }
}

#if arch(x86_64)
@usableFromInline
internal let _countGPRegisters = 6
// Note to future visitors concerning the following SSE register count.
//
// AMD64-ABI section 3.5.7 says -- as recently as v0.99.7, Nov 2014 -- to make
// room in the va_list register-save area for 16 SSE registers (XMM0..15). This
// may seem surprising, because the calling convention of that ABI only uses the
// first 8 SSE registers for argument-passing; why save the other 8?
//
// According to a comment in X86_64ABIInfo::EmitVAArg, in clang's TargetInfo,
// the AMD64-ABI spec is itself in error on this point ("NOTE: 304 is a typo").
// This comment (and calculation) in clang has been there since varargs support
// was added in 2009, in rev be9eb093; so if you're about to change this value
// from 8 to 16 based on reading the spec, probably the bug you're looking for
// is elsewhere.
@usableFromInline
internal let _countSSERegisters = 8
@usableFromInline
internal let _sseRegisterWords = 2
@usableFromInline
internal let _registerSaveWords = _countGPRegisters + _countSSERegisters * _sseRegisterWords
#elseif arch(s390x)
@usableFromInline
internal let _countGPRegisters = 16
@usableFromInline
internal let _registerSaveWords = _countGPRegisters

#elseif arch(arm64) && os(Linux)
// ARM Procedure Call Standard for aarch64. (IHI0055B)
// The va_list type may refer to any parameter in a parameter list may be in one
// of three memory locations depending on its type and position in the argument
// list :
// 1. GP register save area x0 - x7
// 2. 128-bit FP/SIMD register save area q0 - q7
// 3. Stack argument area
@_versioned
internal let _countGPRegisters = 8
@_versioned
internal let _countFPRegisters = 8
@_versioned
internal let _fpRegisterWords = 16 /  MemoryLayout<Int>.size
@_versioned
internal let _registerSaveWords = _countGPRegisters + (_countFPRegisters * _fpRegisterWords)
#endif

#if arch(s390x)
internal typealias _VAUInt = CUnsignedLongLong
internal typealias _VAInt  = Int64
#else
internal typealias _VAUInt = CUnsignedInt
internal typealias _VAInt  = Int32
#endif

/// Invokes the given closure with a C `va_list` argument derived from the
/// given array of arguments.
///
/// The pointer passed as an argument to `body` is valid only during the
/// execution of `withVaList(_:_:)`. Do not store or return the pointer for
/// later use.
///
/// If you need to pass an optional pointer as a `CVarArg` argument, use the
/// `Int(bitPattern:)` initializer to interpret the optional pointer as an
/// `Int` value, which has the same C variadic calling conventions as a pointer
/// on all supported platforms.
///
/// - Parameters:
///   - args: An array of arguments to convert to a C `va_list` pointer.
///   - body: A closure with a `CVaListPointer` parameter that references the
///     arguments passed as `args`. If `body` has a return value, that value
///     is also used as the return value for the `withVaList(_:)` function.
///     The pointer argument is valid only for the duration of the function's
///     execution.
/// - Returns: The return value, if any, of the `body` closure parameter.
@inlinable // FIXME(sil-serialize-all)
public func withVaList<R>(_ args: [CVarArg],
  _ body: (CVaListPointer) -> R) -> R {
  let builder = _VaListBuilder()
  for a in args {
    builder.append(a)
  }
  return _withVaList(builder, body)
}

/// Invoke `body` with a C `va_list` argument derived from `builder`.
@inlinable // FIXME(sil-serialize-all)
internal func _withVaList<R>(
  _ builder: _VaListBuilder,
  _ body: (CVaListPointer) -> R
) -> R {
  let result = body(builder.va_list())
  _fixLifetime(builder)
  return result
}

#if _runtime(_ObjC)
// Excluded due to use of dynamic casting and Builtin.autorelease, neither
// of which correctly work without the ObjC Runtime right now.
// See rdar://problem/18801510

/// Returns a `CVaListPointer` that is backed by autoreleased storage, built
/// from the given array of arguments.
///
/// You should prefer `withVaList(_:_:)` instead of this function. In some
/// uses, such as in a `class` initializer, you may find that the language
/// rules do not allow you to use `withVaList(_:_:)` as intended.
///
/// If you need to pass an optional pointer as a `CVarArg` argument, use the
/// `Int(bitPattern:)` initializer to interpret the optional pointer as an
/// `Int` value, which has the same C variadic calling conventions as a pointer
/// on all supported platforms.
///
/// - Parameter args: An array of arguments to convert to a C `va_list`
///   pointer.
/// - Returns: A pointer that can be used with C functions that take a
///   `va_list` argument.
@inlinable // FIXME(sil-serialize-all)
public func getVaList(_ args: [CVarArg]) -> CVaListPointer {
  let builder = _VaListBuilder()
  for a in args {
    builder.append(a)
  }
  // FIXME: Use some Swift equivalent of NS_RETURNS_INNER_POINTER if we get one.
  Builtin.retain(builder)
  Builtin.autorelease(builder)
  return builder.va_list()
}
#endif

@inlinable // FIXME(sil-serialize-all)
public func _encodeBitsAsWords<T>(_ x: T) -> [Int] {
  let result = [Int](
    repeating: 0,
    count: (MemoryLayout<T>.size + MemoryLayout<Int>.size - 1) / MemoryLayout<Int>.size)
  _sanityCheck(result.count > 0)
  var tmp = x
  // FIXME: use UnsafeMutablePointer.assign(from:) instead of memcpy.
  _memcpy(dest: UnsafeMutablePointer(result._baseAddressIfContiguous!),
          src: UnsafeMutablePointer(Builtin.addressof(&tmp)),
          size: UInt(MemoryLayout<T>.size))
  return result
}

// CVarArg conformances for the integer types.  Everything smaller
// than an Int32 must be promoted to Int32 or CUnsignedInt before
// encoding.

// Signed types
extension Int : CVarArg {
  /// Transform `self` into a series of machine words that can be
  /// appropriately interpreted by C varargs.
  @inlinable // FIXME(sil-serialize-all)
  public var _cVarArgEncoding: [Int] {
    return _encodeBitsAsWords(self)
  }
}

extension Bool : CVarArg {
  public var _cVarArgEncoding: [Int] {
    return _encodeBitsAsWords(_VAInt(self ? 1:0))
  }
}

extension Int64 : CVarArg, _CVarArgAligned {
  /// Transform `self` into a series of machine words that can be
  /// appropriately interpreted by C varargs.
  @inlinable // FIXME(sil-serialize-all)
  public var _cVarArgEncoding: [Int] {
    return _encodeBitsAsWords(self)
  }

  /// Returns the required alignment in bytes of
  /// the value returned by `_cVarArgEncoding`.
  @inlinable // FIXME(sil-serialize-all)
  public var _cVarArgAlignment: Int {
    // FIXME: alignof differs from the ABI alignment on some architectures
    return MemoryLayout.alignment(ofValue: self)
  }
}

extension Int32 : CVarArg {
  /// Transform `self` into a series of machine words that can be
  /// appropriately interpreted by C varargs.
  @inlinable // FIXME(sil-serialize-all)
  public var _cVarArgEncoding: [Int] {
    return _encodeBitsAsWords(_VAInt(self))
  }
}

extension Int16 : CVarArg {
  /// Transform `self` into a series of machine words that can be
  /// appropriately interpreted by C varargs.
  @inlinable // FIXME(sil-serialize-all)
  public var _cVarArgEncoding: [Int] {
    return _encodeBitsAsWords(_VAInt(self))
  }
}

extension Int8 : CVarArg {
  /// Transform `self` into a series of machine words that can be
  /// appropriately interpreted by C varargs.
  @inlinable // FIXME(sil-serialize-all)
  public var _cVarArgEncoding: [Int] {
    return _encodeBitsAsWords(_VAInt(self))
  }
}

// Unsigned types
extension UInt : CVarArg {
  /// Transform `self` into a series of machine words that can be
  /// appropriately interpreted by C varargs.
  @inlinable // FIXME(sil-serialize-all)
  public var _cVarArgEncoding: [Int] {
    return _encodeBitsAsWords(self)
  }
}

extension UInt64 : CVarArg, _CVarArgAligned {
  /// Transform `self` into a series of machine words that can be
  /// appropriately interpreted by C varargs.
  @inlinable // FIXME(sil-serialize-all)
  public var _cVarArgEncoding: [Int] {
    return _encodeBitsAsWords(self)
  }

  /// Returns the required alignment in bytes of
  /// the value returned by `_cVarArgEncoding`.
  @inlinable // FIXME(sil-serialize-all)
  public var _cVarArgAlignment: Int {
    // FIXME: alignof differs from the ABI alignment on some architectures
    return MemoryLayout.alignment(ofValue: self)
  }
}

extension UInt32 : CVarArg {
  /// Transform `self` into a series of machine words that can be
  /// appropriately interpreted by C varargs.
  @inlinable // FIXME(sil-serialize-all)
  public var _cVarArgEncoding: [Int] {
    return _encodeBitsAsWords(_VAUInt(self))
  }
}

extension UInt16 : CVarArg {
  /// Transform `self` into a series of machine words that can be
  /// appropriately interpreted by C varargs.
  @inlinable // FIXME(sil-serialize-all)
  public var _cVarArgEncoding: [Int] {
    return _encodeBitsAsWords(_VAUInt(self))
  }
}

extension UInt8 : CVarArg {
  /// Transform `self` into a series of machine words that can be
  /// appropriately interpreted by C varargs.
  @inlinable // FIXME(sil-serialize-all)
  public var _cVarArgEncoding: [Int] {
    return _encodeBitsAsWords(_VAUInt(self))
  }
}

extension OpaquePointer : CVarArg {
  /// Transform `self` into a series of machine words that can be
  /// appropriately interpreted by C varargs.
  @inlinable // FIXME(sil-serialize-all)
  public var _cVarArgEncoding: [Int] {
    return _encodeBitsAsWords(self)
  }
}

extension UnsafePointer : CVarArg {
  /// Transform `self` into a series of machine words that can be
  /// appropriately interpreted by C varargs.
  @inlinable // FIXME(sil-serialize-all)
  public var _cVarArgEncoding: [Int] {
    return _encodeBitsAsWords(self)
  }
}

extension UnsafeMutablePointer : CVarArg {
  /// Transform `self` into a series of machine words that can be
  /// appropriately interpreted by C varargs.
  @inlinable // FIXME(sil-serialize-all)
  public var _cVarArgEncoding: [Int] {
    return _encodeBitsAsWords(self)
  }
}

#if _runtime(_ObjC)
extension AutoreleasingUnsafeMutablePointer : CVarArg {
  /// Transform `self` into a series of machine words that can be
  /// appropriately interpreted by C varargs.
  @inlinable
  public var _cVarArgEncoding: [Int] {
    return _encodeBitsAsWords(self)
  }
}
#endif

extension Float : _CVarArgPassedAsDouble, _CVarArgAligned {
  /// Transform `self` into a series of machine words that can be
  /// appropriately interpreted by C varargs.
  @inlinable // FIXME(sil-serialize-all)
  public var _cVarArgEncoding: [Int] {
    return _encodeBitsAsWords(Double(self))
  }

  /// Returns the required alignment in bytes of
  /// the value returned by `_cVarArgEncoding`.
  @inlinable // FIXME(sil-serialize-all)
  public var _cVarArgAlignment: Int {
    // FIXME: alignof differs from the ABI alignment on some architectures
    return MemoryLayout.alignment(ofValue: Double(self))
  }
}

extension Double : _CVarArgPassedAsDouble, _CVarArgAligned {
  /// Transform `self` into a series of machine words that can be
  /// appropriately interpreted by C varargs.
  @inlinable // FIXME(sil-serialize-all)
  public var _cVarArgEncoding: [Int] {
    return _encodeBitsAsWords(self)
  }

  /// Returns the required alignment in bytes of
  /// the value returned by `_cVarArgEncoding`.
  @inlinable // FIXME(sil-serialize-all)
  public var _cVarArgAlignment: Int {
    // FIXME: alignof differs from the ABI alignment on some architectures
    return MemoryLayout.alignment(ofValue: self)
  }
}

#if arch(x86_64) || arch(s390x)

/// An object that can manage the lifetime of storage backing a
/// `CVaListPointer`.
@_fixed_layout // FIXME(sil-serialize-all)
@usableFromInline // FIXME(sil-serialize-all)
final internal class _VaListBuilder {

  @_fixed_layout // FIXME(sil-serialize-all)
  @usableFromInline
  internal struct Header {
    @inlinable // FIXME(sil-serialize-all)
    internal init() {}

    @usableFromInline // FIXME(sil-serialize-all)
    internal var gp_offset = CUnsignedInt(0)
    @usableFromInline // FIXME(sil-serialize-all)
    internal var fp_offset =
      CUnsignedInt(_countGPRegisters * MemoryLayout<Int>.stride)
    @usableFromInline // FIXME(sil-serialize-all)
    internal var overflow_arg_area: UnsafeMutablePointer<Int>?
    @usableFromInline // FIXME(sil-serialize-all)
    internal var reg_save_area: UnsafeMutablePointer<Int>?
  }

  @inlinable // FIXME(sil-serialize-all)
  internal init() {
    // prepare the register save area
    storage = ContiguousArray(repeating: 0, count: _registerSaveWords)
  }

  @inlinable // FIXME(sil-serialize-all)
  deinit {}

  @inlinable // FIXME(sil-serialize-all)
  internal func append(_ arg: CVarArg) {
    var encoded = arg._cVarArgEncoding

#if arch(x86_64)
    if arg is _CVarArgPassedAsDouble
      && sseRegistersUsed < _countSSERegisters {
      var startIndex = _countGPRegisters
           + (sseRegistersUsed * _sseRegisterWords)
      for w in encoded {
        storage[startIndex] = w
        startIndex += 1
      }
      sseRegistersUsed += 1
    }
    else if encoded.count == 1
      && !(arg is _CVarArgPassedAsDouble)
      && gpRegistersUsed < _countGPRegisters {
      storage[gpRegistersUsed] = encoded[0]
      gpRegistersUsed += 1
    }
    else {
      for w in encoded {
        storage.append(w)
      }
    }
#elseif arch(s390x)
    if gpRegistersUsed < _countGPRegisters {
      for w in encoded {
        storage[gpRegistersUsed] = w
        gpRegistersUsed += 1
      }
    } else {
      for w in encoded {
        storage.append(w)
      }
    }
#endif

  }

  @inlinable // FIXME(sil-serialize-all)
  internal func va_list() -> CVaListPointer {
    header.reg_save_area = storage._baseAddress
    header.overflow_arg_area
      = storage._baseAddress + _registerSaveWords
    return CVaListPointer(
             _fromUnsafeMutablePointer: UnsafeMutableRawPointer(
               Builtin.addressof(&self.header)))
  }

  @usableFromInline // FIXME(sil-serialize-all)
  internal var gpRegistersUsed = 0
  @usableFromInline // FIXME(sil-serialize-all)
  internal var sseRegistersUsed = 0

  @usableFromInline // FIXME(sil-serialize-all)
  final  // Property must be final since it is used by Builtin.addressof.
  internal var header = Header()
  @usableFromInline // FIXME(sil-serialize-all)
  internal var storage: ContiguousArray<Int>
}

#elseif arch(arm64) && os(Linux)

@_fixed_layout // FIXME(sil-serialize-all)
@_versioned // FIXME(sil-serialize-all)
final internal class _VaListBuilder {
  @_inlineable // FIXME(sil-serialize-all)
  @_versioned // FIXME(sil-serialize-all)
  internal init() {
    // Prepare the register save area.
    allocated = _registerSaveWords
    storage = allocStorage(wordCount: allocated)
    // Append stack arguments after register save area.
    count = allocated
  }

  @_inlineable // FIXME(sil-serialize-all)
  @_versioned // FIXME(sil-serialize-all)
  deinit {
    if let allocatedStorage = storage {
      deallocStorage(wordCount: allocated, storage: allocatedStorage)
    }
  }

  @_inlineable // FIXME(sil-serialize-all)
  @_versioned // FIXME(sil-serialize-all)
  internal func append(_ arg: CVarArg) {
    var encoded = arg._cVarArgEncoding

    if arg is _CVarArgPassedAsDouble
      && fpRegistersUsed < _countFPRegisters {
      var startIndex = (fpRegistersUsed * _fpRegisterWords)
      for w in encoded {
        storage[startIndex] = w
        startIndex += 1
      }
      fpRegistersUsed += 1
    } else if encoded.count == 1
      && !(arg is _CVarArgPassedAsDouble)
      && gpRegistersUsed < _countGPRegisters {
      var startIndex = ( _fpRegisterWords * _countFPRegisters) + gpRegistersUsed
      storage[startIndex] = encoded[0]
      gpRegistersUsed += 1
    } else {
      // Arguments in stack slot.
      appendWords(encoded)
    }
  }

  @_inlineable // FIXME(sil-serialize-all)
  @_versioned // FIXME(sil-serialize-all)
  internal func va_list() -> CVaListPointer {
    let vr_top = storage + (_fpRegisterWords * _countFPRegisters)
    let gr_top = vr_top + _countGPRegisters

    return CVaListPointer(__stack: gr_top, __gr_top: gr_top,
                          __vr_top: vr_top, __gr_off: -64, __vr_off: -128)
  }

  @_inlineable // FIXME(sil-serialize-all)
  @_versioned // FIXME(sil-serialize-all)
  internal func appendWords(_ words: [Int]) {
    let newCount = count + words.count
    if newCount > allocated {
      let oldAllocated = allocated
      let oldStorage = storage
      let oldCount = count

      allocated = max(newCount, allocated * 2)
      let newStorage = allocStorage(wordCount: allocated)
      storage = newStorage
      // Count is updated below.
      if let allocatedOldStorage = oldStorage {
        newStorage.moveInitialize(from: allocatedOldStorage, count: oldCount)
        deallocStorage(wordCount: oldAllocated, storage: allocatedOldStorage)
      }
    }

    let allocatedStorage = storage!
    for word in words {
      allocatedStorage[count] = word
      count += 1
    }
  }

  @_inlineable // FIXME(sil-serialize-all)
  @_versioned // FIXME(sil-serialize-all)
  internal func rawSizeAndAlignment(
    _ wordCount: Int
  ) -> (Builtin.Word, Builtin.Word) {
    return ((wordCount * MemoryLayout<Int>.stride)._builtinWordValue,
      requiredAlignmentInBytes._builtinWordValue)
  }

  @_inlineable // FIXME(sil-serialize-all)
  @_versioned // FIXME(sil-serialize-all)
  internal func allocStorage(wordCount: Int) -> UnsafeMutablePointer<Int> {
    let (rawSize, rawAlignment) = rawSizeAndAlignment(wordCount)
    let rawStorage = Builtin.allocRaw(rawSize, rawAlignment)
    return UnsafeMutablePointer<Int>(rawStorage)
  }

  @_versioned // FIXME(sil-serialize-all)
  internal func deallocStorage(
    wordCount: Int, storage: UnsafeMutablePointer<Int>
  ) {
    let (rawSize, rawAlignment) = rawSizeAndAlignment(wordCount)
    Builtin.deallocRaw(storage._rawValue, rawSize, rawAlignment)
  }

  @_versioned // FIXME(sil-serialize-all)
  internal let requiredAlignmentInBytes = MemoryLayout<Double>.alignment

  @_versioned // FIXME(sil-serialize-all)
  internal var count = 0

  @_versioned // FIXME(sil-serialize-all)
  internal var allocated = 0

  @_versioned // FIXME(sil-serialize-all)
  internal var storage: UnsafeMutablePointer<Int>!

  @_versioned // FIXME(sil-serialize-all)
  internal var gpRegistersUsed = 0

  @_versioned // FIXME(sil-serialize-all)
  internal var fpRegistersUsed = 0

  @_versioned // FIXME(sil-serialize-all)
  internal var overflowWordsUsed = 0
}

#else

/// An object that can manage the lifetime of storage backing a
/// `CVaListPointer`.
@_fixed_layout // FIXME(sil-serialize-all)
@usableFromInline // FIXME(sil-serialize-all)
final internal class _VaListBuilder {

  @inlinable // FIXME(sil-serialize-all)
  internal init() {}

  @inlinable // FIXME(sil-serialize-all)
  internal func append(_ arg: CVarArg) {
    // Write alignment padding if necessary.
    // This is needed on architectures where the ABI alignment of some
    // supported vararg type is greater than the alignment of Int, such
    // as non-iOS ARM. Note that we can't use alignof because it
    // differs from ABI alignment on some architectures.
#if arch(arm) && !os(iOS)
    if let arg = arg as? _CVarArgAligned {
      let alignmentInWords = arg._cVarArgAlignment / MemoryLayout<Int>.size
      let misalignmentInWords = count % alignmentInWords
      if misalignmentInWords != 0 {
        let paddingInWords = alignmentInWords - misalignmentInWords
        appendWords([Int](repeating: -1, count: paddingInWords))
      }
    }
#endif

    // Write the argument's value itself.
    appendWords(arg._cVarArgEncoding)
  }

  // NB: This function *cannot* be @inlinable because it expects to project
  // and escape the physical storage of `_VaListBuilder.alignedStorageForEmptyVaLists`.
  // Marking it inlinable will cause it to resiliently use accessors to
  // project `_VaListBuilder.alignedStorageForEmptyVaLists` as a computed
  // property.
  @usableFromInline // FIXME(sil-serialize-all)
  internal func va_list() -> CVaListPointer {
    // Use Builtin.addressof to emphasize that we are deliberately escaping this
    // pointer and assuming it is safe to do so.
    let emptyAddr = UnsafeMutablePointer<Int>(
      Builtin.addressof(&_VaListBuilder.alignedStorageForEmptyVaLists))
    return CVaListPointer(_fromUnsafeMutablePointer: storage ?? emptyAddr)
  }

  // Manage storage that is accessed as Words
  // but possibly more aligned than that.
  // FIXME: this should be packaged into a better storage type

  @inlinable // FIXME(sil-serialize-all)
  internal func appendWords(_ words: [Int]) {
    let newCount = count + words.count
    if newCount > allocated {
      let oldAllocated = allocated
      let oldStorage = storage
      let oldCount = count

      allocated = max(newCount, allocated * 2)
      let newStorage = allocStorage(wordCount: allocated)
      storage = newStorage
      // count is updated below

      if let allocatedOldStorage = oldStorage {
        newStorage.moveInitialize(from: allocatedOldStorage, count: oldCount)
        deallocStorage(wordCount: oldAllocated, storage: allocatedOldStorage)
      }
    }

    let allocatedStorage = storage!
    for word in words {
      allocatedStorage[count] = word
      count += 1
    }
  }

  @inlinable // FIXME(sil-serialize-all)
  internal func rawSizeAndAlignment(
    _ wordCount: Int
  ) -> (Builtin.Word, Builtin.Word) {
    return ((wordCount * MemoryLayout<Int>.stride)._builtinWordValue,
      requiredAlignmentInBytes._builtinWordValue)
  }

  @inlinable // FIXME(sil-serialize-all)
  internal func allocStorage(wordCount: Int) -> UnsafeMutablePointer<Int> {
    let (rawSize, rawAlignment) = rawSizeAndAlignment(wordCount)
    let rawStorage = Builtin.allocRaw(rawSize, rawAlignment)
    return UnsafeMutablePointer<Int>(rawStorage)
  }

  @usableFromInline // FIXME(sil-serialize-all)
  internal func deallocStorage(
    wordCount: Int,
    storage: UnsafeMutablePointer<Int>
  ) {
    let (rawSize, rawAlignment) = rawSizeAndAlignment(wordCount)
    Builtin.deallocRaw(storage._rawValue, rawSize, rawAlignment)
  }

  @inlinable // FIXME(sil-serialize-all)
  deinit {
    if let allocatedStorage = storage {
      deallocStorage(wordCount: allocated, storage: allocatedStorage)
    }
  }

  // FIXME: alignof differs from the ABI alignment on some architectures
  @usableFromInline // FIXME(sil-serialize-all)
  internal let requiredAlignmentInBytes = MemoryLayout<Double>.alignment
  @usableFromInline // FIXME(sil-serialize-all)
  internal var count = 0
  @usableFromInline // FIXME(sil-serialize-all)
  internal var allocated = 0
  @usableFromInline // FIXME(sil-serialize-all)
  internal var storage: UnsafeMutablePointer<Int>?

  internal static var alignedStorageForEmptyVaLists: Double = 0
}

#endif

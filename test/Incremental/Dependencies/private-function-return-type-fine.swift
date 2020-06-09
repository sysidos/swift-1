// REQUIRES: shell
// Also uses awk:
// XFAIL OS=windows

// RUN: %target-swift-frontend -emit-silgen -primary-file %s %S/Inputs/InterestingType.swift -DOLD -emit-reference-dependencies-path %t.swiftdeps -module-name main -disable-experimental-private-intransitive-dependencies | %FileCheck %s -check-prefix=CHECK-OLD
// RUN: %S/../../Inputs/process_fine_grained_swiftdeps.sh <%t.swiftdeps >%t-processed.swiftdeps
// RUN: %FileCheck -check-prefix=CHECK-DEPS %s < %t-processed.swiftdeps

// RUN: %target-swift-frontend -emit-silgen -primary-file %s %S/Inputs/InterestingType.swift -DNEW -emit-reference-dependencies-path %t.swiftdeps -module-name main -disable-experimental-private-intransitive-dependencies | %FileCheck %s -check-prefix=CHECK-NEW
// RUN: %S/../../Inputs/process_fine_grained_swiftdeps.sh <%t.swiftdeps >%t-processed.swiftdeps
// RUN: %FileCheck -check-prefix=CHECK-DEPS %s < %t-processed.swiftdeps

private func testReturnType() -> InterestingType { fatalError() }

// CHECK-OLD: sil_global @$s4main1x{{[^ ]+}} : $Int
// CHECK-NEW: sil_global @$s4main1x{{[^ ]+}} : $Double
public var x = testReturnType() + 0

// CHECK-DEPS: topLevel interface  '' InterestingType false

//! Derives observable callback types not re-exported by the SDK.
//!
//! The reflection chain below depends on internal signatures of the SDK
//! commit pinned in build.zig.zon. A compile error in this file after a
//! dependency update means an upstream signature changed; re-derive the
//! types from the current Meter API instead of patching call sites.

const sdk = @import("opentelemetry-sdk");

pub const metrics = sdk.metrics;
pub const MeterProvider = metrics.MeterProvider;

const get_meter_return = @typeInfo(@TypeOf(MeterProvider.getMeter)).@"fn".return_type.?;
const meter_pointer = @typeInfo(get_meter_return).error_union.payload;
pub const Meter = @typeInfo(meter_pointer).pointer.child;

const create_gauge = @typeInfo(@TypeOf(Meter.createObservableGauge)).@"fn";
pub const ObservedContext = create_gauge.params[2].type.?;

const optional_callback_slice = create_gauge.params[3].type.?;
const callback_slice = @typeInfo(optional_callback_slice).optional.child;
pub const ObserveMeasures = @typeInfo(callback_slice).pointer.child;

const callback_function = @typeInfo(ObserveMeasures).pointer.child;
const callback_info = @typeInfo(callback_function).@"fn";
pub const ObserveResult = callback_info.return_type.?;
pub const MeasurementsData = @typeInfo(ObserveResult).error_union.payload;

const integer_measurements = @FieldType(MeasurementsData, "int");
pub const IntegerDataPoint = @typeInfo(integer_measurements).pointer.child;

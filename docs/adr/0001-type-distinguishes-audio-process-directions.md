# 0001. Type distinguishes audio process directions

Status: Accepted

## Context

`MeetingDetector.sample` receives bundle IDs for applications producing audio
output and applications consuming microphone input. Both values were `[String]`,
so swapping them in the live Core Audio wiring compiled and left the existing
test suite green. The two headset signals were independently supplied `Bool`
values and were similarly easy to exchange.

The detector assigns meaning to these directions: output contributes to the
playing condition while microphone input contributes to the microphone-in-use
condition. This is a core recording trigger invariant.

## Decision

`AudioProcessLookup` will return `OutputProducers` and `InputConsumers` value
types rather than bare string arrays. `MeetingDetector.sample` will accept those
types in its injectable overload. `AudioDeviceLookup` will return a single
`HeadsetState` value containing both headset flags.

Consumers that need raw identifiers outside the detector will explicitly read
the appropriate value's `bundleIDs` property.

## Consequences

Exchanging output producers and input consumers in the live wiring becomes a
compile-time error. Passing headset state as one value removes the two-Boolean
exchange point.

This does not validate the Core Audio queries themselves or prove that the
captured tracks have the intended real-world meaning. Those remain the scope of
the separate real-meeting E2E task.

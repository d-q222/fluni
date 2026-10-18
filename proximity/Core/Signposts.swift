import os

/// Points of Interest for Instruments (Time Profiler, Animation Hitches, App Launch all show them), so
/// launch, the 1 s tick and the map load can be measured on a phone instead of guessed. Free when no trace
/// is recording.
enum Signposts {
    static let poi = OSSignposter(subsystem: "com.fluni", category: .pointsOfInterest)
}

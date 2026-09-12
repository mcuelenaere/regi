import Foundation

/// `CGEventGetTimestamp` and `IOHIDValueGetTimeStamp` both report mach absolute
/// time, which is not nanoseconds on every machine — the timebase ratio is 1:1
/// on Apple Silicon but not historically, so converting explicitly is the only
/// portable option.
public enum MachClock {
    public static let timebase: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (info.numer, info.denom)
    }()

    public static func nanos(fromMachAbsolute ticks: UInt64) -> UInt64 {
        let (n, d) = timebase
        if n == d { return ticks }
        return ticks &* UInt64(n) / UInt64(d)
    }

    /// Monotonic, and unlike `mach_absolute_time` it keeps counting across
    /// system sleep — so a target that naps mid-run does not produce a time
    /// discontinuity in the record.
    public static func continuousNanos() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    }

    public static func absoluteNanos() -> UInt64 {
        nanos(fromMachAbsolute: mach_absolute_time())
    }
}

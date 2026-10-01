public enum DetectionState: String, Equatable, Sendable {
    case hidden
    case observed
    case tracked
    case hunted
    case lockdown

    public static func projected(_ exposure: Int) -> DetectionState {
        switch exposure {
        case 0..<200: .hidden
        case 200..<450: .observed
        case 450..<700: .tracked
        case 700..<1000: .hunted
        default: .lockdown
        }
    }
}

public enum ExposureReason: String, Equatable, Sendable {
    case cameraContact
    case recovery
    case cameraTamper
    case fogPulse
    case observationPulse
    case forcedLockdown
}

public struct ExposureState: Equatable, Sendable {
    public var exposure: Int
    public var detectionState: DetectionState
    public var noContactTicks: Int
    public var lockdownEntered: Bool
    public var peak: Int
    /// D-101 (exposure.md § Quiet approach): true until the Detection State
    /// reaches `tracked` or higher before M-C activates; latched false.
    public var quietApproach: Bool

    public init(
        exposure: Int = 0,
        detectionState: DetectionState = .hidden,
        noContactTicks: Int = 0,
        lockdownEntered: Bool = false
    ) {
        self.exposure = exposure
        self.detectionState = detectionState
        self.noContactTicks = noContactTicks
        self.lockdownEntered = lockdownEntered
        self.peak = exposure
        self.quietApproach = true
    }

    /// `exposure.md` constants: Camera Tamper Spike per destruction (D-086).
    public static let tamperSpike = 150

    /// `exposure.md` constants: Tamper floor, per Camera destroyed this run (D-084).
    public static let tamperFloorPerCamera = 150

    public static func contactDelta(cameraCount n: Int, signalJammer: Bool) -> Int {
        guard n > 0 else { return 0 }
        var delta = min(5, 2 + n - 1)
        if signalJammer {
            delta = max(1, delta - 1)
        }
        return delta
    }

    public struct Resolution: Equatable, Sendable {
        public var contactDelta: Int
        public var tamperApplied: Int
        public var before: Int
        public var after: Int
        public var stateBefore: DetectionState
        public var stateAfter: DetectionState
        public var lockdownEnteredThisTick: Bool
        public var reason: ExposureReason
    }

    /// Phase 13–14: surviving contacts, then ordered Tamper, then state/Lockdown.
    public mutating func resolveTick(
        survivingContactCount: Int,
        tamperAmounts: [Int],
        signalJammer: Bool,
        forceLockdown: Bool = false,
        destroyedCameras: Int = 0
    ) -> Resolution {
        let before = exposure
        let stateBefore = detectionState
        var reason: ExposureReason = .cameraContact
        var contact = 0
        var tamper = 0

        if lockdownEntered || forceLockdown {
            if forceLockdown && !lockdownEntered {
                exposure = 1000
                reason = .forcedLockdown
            } else {
                exposure = 1000
            }
            noContactTicks = survivingContactCount > 0 ? 0 : noContactTicks + (survivingContactCount == 0 ? 1 : 0)
            if survivingContactCount > 0 { noContactTicks = 0 }
        } else if survivingContactCount > 0 {
            noContactTicks = 0
            contact = Self.contactDelta(cameraCount: survivingContactCount, signalJammer: signalJammer)
            exposure += contact
            reason = .cameraContact
        } else {
            noContactTicks += 1
            // D-084 Tamper floor: recovery stops at 150 × Cameras destroyed.
            // It only limits recovery; it never raises Exposure.
            let floor = Self.tamperFloorPerCamera * destroyedCameras
            if noContactTicks > 60, exposure > floor {
                exposure = max(floor, exposure - 2)
                reason = .recovery
            }
        }

        for amount in tamperAmounts {
            tamper += amount
            exposure += amount
            reason = .cameraTamper
        }

        if forceLockdown {
            exposure = 1000
            reason = .forcedLockdown
        }

        exposure = min(1000, max(0, exposure))
        if exposure > peak { peak = exposure }

        var lockdownThisTick = false
        if exposure >= 1000 {
            exposure = 1000
            if !lockdownEntered {
                lockdownEntered = true
                lockdownThisTick = true
            }
        }

        detectionState = lockdownEntered ? .lockdown : DetectionState.projected(exposure)
        if lockdownEntered { exposure = 1000 }

        return Resolution(
            contactDelta: contact,
            tamperApplied: tamper,
            before: before,
            after: exposure,
            stateBefore: stateBefore,
            stateAfter: detectionState,
            lockdownEnteredThisTick: lockdownThisTick,
            reason: reason
        )
    }
}

@testable import SurveillanceCore

extension Simulation {
    /// The bundled run with no Transit Patrol (D-091), for vectors that
    /// isolate another rule. The patrol spawns three unaware standard enemies
    /// in Z-02 on the first tick, which a vector about sight, spawning,
    /// targeting, or ally alerts would otherwise also see, shoot, or alert.
    /// The patrol has its own vectors (`TransitPatrolTests`).
    static func withoutPatrol(seed: UInt64, content: CombatContent = .bundled()) throws -> Simulation {
        var arena = try ArenaManifest.bundled()
        arena.patrols = []
        return try Simulation(seed: seed, arena: arena, content: content)
    }
}

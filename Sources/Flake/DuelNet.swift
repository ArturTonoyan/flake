import Foundation

enum DuelNetCommand: UInt8 {
    case challenge = 1
    case accept = 2
    case decline = 3
    case throwShot = 4
    case hpSync = 5
    case roundEnd = 6
    case rematchAsk = 7
    case rematchOk = 8
    case leave = 9
    case moveSync = 10
}

struct DuelNetEvent {
    let fromPeerID: UInt64
    let fromName: String
    let command: DuelNetCommand
    /// Payload floats (meaning depends on command).
    let values: [Float]
    /// Sender's wins.
    let scoreA: UInt16
    /// Sender's view of opponent wins.
    let scoreB: UInt16
}

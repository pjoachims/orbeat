/// Everything the BLE hub reports upward. The app layer maps these onto
/// its UI model and policies; the BLE component knows nothing about either.
enum SensorEvent {
    case status(String)                    // human-readable scan/link state
    case heartLinkUp(device: String)
    case heartLinkDown
    case powerLinkUp(device: String)
    case powerLinkDown
    case heartRate(HeartRateReading)
    case power(PowerReading)
    case handlebar([HandlebarInput])       // fresh paddle presses
    case trainerReady                      // FTMS control point discovered & claimed
    case trainerLost
    case trainerMode(TrainerMode)          // trainer reported its target (set by any client)
}

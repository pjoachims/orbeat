import Foundation

/// Real Fitbit Web API hook-up point.
///
/// The app ships with a simulated signal (RideModel.tick). To use a real
/// Fitbit device, fill this in:
///
/// 1. Register an app at https://dev.fitbit.com → get clientID + secret.
/// 2. OAuth2 PKCE flow, scope `heartrate`, redirect to a localhost URL.
/// 3. Poll GET /1/user/-/activities/heart/date/today/1d/1sec.json
///    (intraday access requires Fitbit approval) and feed values into
///    `RideModel.bpm` / `history` instead of the random walk.
///
/// Left as a stub so the app runs offline out of the box.
enum FitbitClient {
    static let authorizeURL = "https://www.fitbit.com/oauth2/authorize"
    static let tokenURL = "https://api.fitbit.com/oauth2/token"
    static let intradayPath = "/1/user/-/activities/heart/date/today/1d/1sec.json"

    static var isConfigured: Bool { false }
}

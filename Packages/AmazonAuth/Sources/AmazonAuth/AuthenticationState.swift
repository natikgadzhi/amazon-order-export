/// Lifecycle of the auth session as the login flow progresses.
public enum AuthenticationState: Sendable, Equatable {
  case new
  case unauthenticated
  case authenticating
  case authenticated
}

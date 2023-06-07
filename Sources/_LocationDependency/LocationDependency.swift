#if canImport(CoreLocation)
  import CoreLocation
  import Dependencies
  @_spi(Internals) import DependenciesAdditionsBasics
  import LocationManagerDependency

  extension DependencyValues {
    /// An abstraction of `CLLocationManager`, the central object for managing
    /// notification-related activities for your app or app extension.
    public var locationClient: LocationClient {
      get { self[LocationClient.self] }
      set { self[LocationClient.self] = newValue }
    }
  }

  extension LocationClient: DependencyKey {
    public static var liveValue: LocationClient { .system }
    public static var testValue: LocationClient { .unimplemented }
    public static var previewValue: LocationClient { .system }
  }

  public struct LocationClient: Sendable, ConfigurableProxy {
    public struct Implementation: Sendable {
      // TODO: Try to add `@MainActor`
      @FunctionProxy public var getLocation: @Sendable () async throws -> CLLocationCoordinate2D
    }

    @_spi(Internals) public var _implementation: Implementation

    @Sendable
    public func getLocation() async throws -> CLLocationCoordinate2D {
      try await self._implementation.getLocation()
    }
  }

  enum LocationError: Error {
    case noLocation
    case notAuthorized(CLAuthorizationStatus)
    case error(CLError)
  }

  enum DelegateError: Swift.Error {
    case deinitialized
  }

  final class LocationManagerDelegate: NSObject, CLLocationManagerDelegate, Sendable {
    private let locationContinuations = LockIsolated<[CheckedContinuation<CLLocationCoordinate2D, any Error>]>([])
    private let authorizationContinuations = LockIsolated<[CheckedContinuation<CLAuthorizationStatus, Never>]>([])

    deinit {
      self.locationContinuations.withValue { continuations in
        while !continuations.isEmpty {
          continuations.removeFirst().resume(throwing: DelegateError.deinitialized)
        }
      }
    }

    func registerLocationContinuation(
      _ continuation: CheckedContinuation<CLLocationCoordinate2D, any Error>
    ) {
      self.locationContinuations.withValue {
        $0.append(continuation)
      }
    }
    func registerAuthorizationContinuation(
      _ continuation: CheckedContinuation<CLAuthorizationStatus, Never>
    ) {
      self.authorizationContinuations.withValue {
        $0.append(continuation)
      }
    }

    private func locationReceived(_ res: Result<CLLocationCoordinate2D, LocationError>) {
      self.locationContinuations.withValue { continuations in
        while !continuations.isEmpty {
          continuations.removeFirst().resume(with: res)
        }
      }
    }

    func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
      if let locationClient = locations.first {
        self.locationReceived(.success(locationClient.coordinate))
      } else {
        self.locationReceived(.failure(LocationError.noLocation))
      }
    }

    func locationManager(_: CLLocationManager, didFailWithError error: Error) {
      self.locationReceived(.failure(LocationError.error(error as! CLError)))
    }

    @available(macOS 11, *)
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
      self.authorizationContinuations.withValue { continuations in
        let status = manager.authorizationStatus
        while !continuations.isEmpty {
          continuations.removeFirst().resume(returning: status)
        }
      }
    }

    @available(macOS, deprecated: 11)
    func locationManager(
      _ manager: CLLocationManager,
      didChangeAuthorization status: CLAuthorizationStatus
    ) {
      self.authorizationContinuations.withValue { continuations in
        while !continuations.isEmpty {
          continuations.removeFirst().resume(returning: status)
        }
      }
    }
  }

  fileprivate extension LocationManager {
    var _delegate: LocationManagerDelegate? {
      let delegate = self.delegate as? LocationManagerDelegate
      assert(delegate != nil)
      return delegate
    }
  }

  extension CLAuthorizationStatus {
    var _isAuthorized: Bool {
      switch self {
      case .authorized, .authorizedAlways, .authorizedWhenInUse:
        return true
      case .denied, .notDetermined, .restricted:
        return false
      @unknown default:
        return false
      }
    }
  }

  extension LocationClient {
    static var system: LocationClient {
      withDependencies {
        $0.locationManager.delegate = LocationManagerDelegate()
      } operation: {
        let requestWhenInUseAuthorization = { @Sendable @MainActor in
          @Dependency(\.locationManager.authorizationStatus) var status
          if status._isAuthorized {
            return status
          }

          return await withCheckedContinuation { continuation in
            @Dependency(\.locationManager) var locationManager
            locationManager._delegate?.registerAuthorizationContinuation(continuation)
            locationManager.requestWhenInUseAuthorization()
          }
        }

        let _implementation = Implementation(
          getLocation: .init {
            @Dependency(\.locationManager) var locationManager

            if !locationManager.authorizationStatus._isAuthorized {
              let status = await requestWhenInUseAuthorization()
              if !status._isAuthorized {
                throw LocationError.notAuthorized(status)
              }
            }

            let locationClient = try await withCheckedThrowingContinuation { continuation in
              locationManager._delegate?.registerLocationContinuation(continuation)
              locationManager.requestLocation()
            }

            return locationClient
          }
        )
        return LocationClient(_implementation: _implementation)
      }
    }

    static let unimplemented = LocationClient(
      _implementation: .init(
        getLocation: .unimplemented(
          #"@Dependency(\.locationClient.getLocation)"#)
      ))
  }

#endif

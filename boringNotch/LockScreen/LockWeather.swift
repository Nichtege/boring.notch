//
//  LockWeather.swift
//  boringNotch
//
//  Weather for the lock screen from Open-Meteo, which is free and needs no key.
//

import Defaults
import Foundation

struct LockWeatherPlace: Codable, Equatable, Hashable, Defaults.Serializable {
    var name: String
    var region: String
    var latitude: Double
    var longitude: Double
}

struct LockWeatherData: Codable, Equatable, Defaults.Serializable {
    var temperature: Double
    var code: Int
    var isDay: Bool
    var high: Double
    var low: Double
    var sunrise: Date?
    var sunset: Date?
    var fetched: Date

    /// SF Symbol for the WMO weather code.
    var symbol: String {
        switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...57: "cloud.drizzle.fill"
        case 61...67, 80...82: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    var summary: LocalizedStringResource {
        switch code {
        case 0: "Clear"
        case 1, 2: "Partly cloudy"
        case 3: "Cloudy"
        case 45, 48: "Fog"
        case 51...57: "Drizzle"
        case 61...67, 80...82: "Rain"
        case 71...77, 85, 86: "Snow"
        case 95...99: "Thunderstorm"
        default: "Cloudy"
        }
    }
}

@MainActor
final class LockWeather {
    static let shared = LockWeather()

    /// Not more often than this, however often the screen locks
    private static let maxAge: TimeInterval = 30 * 60
    private var isFetching = false

    private init() {}

    func refreshIfStale() {
        guard let place = Defaults[.lockScreenWeatherPlace], !isFetching else { return }
        if let data = Defaults[.lockScreenWeather], Date().timeIntervalSince(data.fetched) < Self.maxAge {
            return
        }
        isFetching = true
        Task {
            if let data = await Self.fetch(place) {
                // The place may have changed while this was on its way
                if Defaults[.lockScreenWeatherPlace] == place {
                    Defaults[.lockScreenWeather] = data
                }
            }
            isFetching = false
        }
    }

    func choose(_ place: LockWeatherPlace?) {
        Defaults[.lockScreenWeatherPlace] = place
        Defaults[.lockScreenWeather] = nil
        refreshIfStale()
    }

    private struct Forecast: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let weather_code: Int
            let is_day: Int
        }
        struct Daily: Decodable {
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
            let sunrise: [Double]
            let sunset: [Double]
        }
        let current: Current
        let daily: Daily
    }

    private static func fetch(_ place: LockWeatherPlace) async -> LockWeatherData? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(place.latitude)),
            URLQueryItem(name: "longitude", value: String(place.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,sunrise,sunset"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1"),
        ]
        guard
            let url = components.url,
            let (data, response) = try? await URLSession.shared.data(from: url),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let forecast = try? JSONDecoder().decode(Forecast.self, from: data),
            let high = forecast.daily.temperature_2m_max.first,
            let low = forecast.daily.temperature_2m_min.first
        else { return nil }
        return LockWeatherData(
            temperature: forecast.current.temperature_2m,
            code: forecast.current.weather_code,
            isDay: forecast.current.is_day == 1,
            high: high,
            low: low,
            sunrise: forecast.daily.sunrise.first.map { Date(timeIntervalSince1970: $0) },
            sunset: forecast.daily.sunset.first.map { Date(timeIntervalSince1970: $0) },
            fetched: Date()
        )
    }

    private struct Geocoding: Decodable {
        struct Result: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
            let country: String?
            let admin1: String?
        }
        let results: [Result]?
    }

    /// Places with that name, best match first.
    static func search(_ name: String) async -> [LockWeatherPlace] {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "count", value: "5"),
            URLQueryItem(name: "language", value: Locale.current.language.languageCode?.identifier ?? "en"),
        ]
        guard
            let url = components.url,
            let (data, _) = try? await URLSession.shared.data(from: url),
            let found = try? JSONDecoder().decode(Geocoding.self, from: data)
        else { return [] }
        return (found.results ?? []).map {
            LockWeatherPlace(
                name: $0.name,
                region: [$0.admin1, $0.country].compactMap { $0 }.joined(separator: ", "),
                latitude: $0.latitude,
                longitude: $0.longitude
            )
        }
    }
}

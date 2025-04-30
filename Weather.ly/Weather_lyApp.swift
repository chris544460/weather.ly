//
//  Weather_lyApp.swift
//  Weather.ly
//
//  Created 2025‑04‑19
//

import Foundation
import SwiftUI
import Combine
import MapKit
import UserNotifications
import OpenMeteoSdk

// MARK: – App entry
@main
struct WeatherlyApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $viewModel.navigationPath) {
                CityListView()
                    .environmentObject(viewModel)
                    .navigationDestination(for: City.self) { city in
                        CalendarView(city: city)
                            .environmentObject(viewModel)
                    }
            }
        }
    }
}

// MARK: – View‑model
final class AppViewModel: ObservableObject {
    @Published var cities: [City]          = []
    @Published var navigationPath          = NavigationPath()
    @Published var criteria                = DayCriteria()
    /// true = Celsius, false = Fahrenheit
    @Published var useCelsius: Bool =
        UserDefaults.standard.object(forKey: AppViewModel.unitsKey) as? Bool ?? false {
        didSet { saveUnits() }
    }
    /// Cached good‑windows keyed by city.id
    @Published var cachedWindows: [UUID: [GoodWindow]] = [:]

    let weatherService = WeatherService()
    var cancellables   = Set<AnyCancellable>()

    func addCity(_ city: City) {
        cities.append(city)
        saveCities()
    }
    
    // Published prefs
    @Published var notificationsEnabled: Bool =
        UserDefaults.standard.object(forKey: AppViewModel.notifyEnabledKey) as? Bool ?? false {
        didSet { saveNotificationPrefs() }
    }

    /// lead times expressed in hours (can hold several values, e.g. [2, 24, 72])
    @Published var notifyLeadHours: [Int] =
        (UserDefaults.standard.array(forKey: AppViewModel.notifyLeadHoursKey) as? [Int]) ?? [24] {
        didSet { saveNotificationPrefs() }
    }
    
    // new @Published properties (place with the other @Published vars)
    // MARK: – Published work‑hours prefs
    @Published var workStartHour: Int? =
        UserDefaults.standard.object(forKey: AppViewModel.workStartKey) as? Int {
        didSet { saveWorkHours() }   // ← uppercase W
    }

    @Published var workEndHour: Int? =
        UserDefaults.standard.object(forKey: AppViewModel.workEndKey) as? Int {
        didSet { saveWorkHours() }   // ← uppercase W
    }

    // …
    
    private func saveWorkHours() {
        UserDefaults.standard.set(workStartHour, forKey: AppViewModel.workStartKey)
        UserDefaults.standard.set(workEndHour,   forKey: AppViewModel.workEndKey)
    }

    

    
    /// Delete one or more cities and persist the change
    func deleteCities(at offsets: IndexSet) {
        for idx in offsets {
            let city = cities[idx]
            if let wins = cachedWindows[city.id] {
                UNUserNotificationCenter.current()
                    .removePendingNotificationRequests(
                        withIdentifiers: wins.map { "win-\(city.id)-\($0.id)" })
            }
        }
        cities.remove(atOffsets: offsets)
        saveCities()
    }

    func fetchForecasts(for city: City) -> AnyPublisher<[DailyForecast], Error> {
        weatherService.fetchForecast(for: city)
    }

    // MARK: - Persistence (UserDefaults JSON)
    // inside AppViewModel
    private static let citiesKey   = "savedCities"
    private static let criteriaKey = "savedCriteria"
    private static let unitsKey    = "savedUnits"
    private static let windowsKey  = "savedWindows"
    private static let notifyEnabledKey   = "notifyEnabled"
    // savedNotifyLeadHours
    private static let notifyLeadHoursKey = "notifyLeadHours"
    // new keys (put near the other static keys)
    private static let workStartKey = "workStartHour"
    private static let workEndKey   = "workEndHour"

    init() {
        loadCities()
        loadCriteria()
        loadWindows()
        purgeExpiredWindows()
        requestNotificationPermission()
    }


    // MARK: – Notifications
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func saveNotificationPrefs() {
        UserDefaults.standard.set(notificationsEnabled, forKey: Self.notifyEnabledKey)
        UserDefaults.standard.set(notifyLeadHours, forKey: Self.notifyLeadHoursKey)
        rescheduleAll()
    }
    

    /// Schedule alerts for every good‑weather window of one city
    func scheduleNotifications(for city: City, windows: [GoodWindow]) {
        guard notificationsEnabled else { return }

        let center = UNUserNotificationCenter.current()

        // Clear older requests for this city
        center.removePendingNotificationRequests(
            withIdentifiers: windows.map { "win-\(city.id)-\($0.id)" })

        for lead in notifyLeadHours {
            for w in windows {
                let fireDate = w.from.addingTimeInterval(TimeInterval(lead * 3600))
                guard fireDate > Date() else { continue }

                var comps = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: fireDate)
                comps.second = 0

                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)

                let content = UNMutableNotificationContent()
                content.title = "Great weather coming!"
                content.body  = "\(city.name): starts at " +
                    DateFormatter.localizedString(from: w.from,
                                                  dateStyle: .none,
                                                  timeStyle: .short)
                content.sound = .default

                if let plan = w.plan {
                    content.title = plan
                    content.body  = "\(city.name) – starts " +
                        DateFormatter.localizedString(from: w.from,
                                                      dateStyle: .none,
                                                      timeStyle: .short)
                } else {
                    content.title = "Great weather coming!"
                    content.body  = "\(city.name) – you haven’t planned anything yet"
                }
                
                let reqID = "win-\(city.id)-\(w.id)-\(lead)h"
                let req   = UNNotificationRequest(identifier:reqID,
                                                  content: content,
                                                  trigger: trigger)
                center.add(req)
            }
        }
    }

    /// Wipe everything and reschedule from cached data
    func rescheduleAll() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        for c in cities {
            if let wins = cachedWindows[c.id] {
                scheduleNotifications(for: c, windows: wins)
            }
        }
    }
    

    private func saveUnits() {
        UserDefaults.standard.set(useCelsius, forKey: AppViewModel.unitsKey)
    }

    private func saveCities() {
        if let data = try? JSONEncoder().encode(cities) {
            UserDefaults.standard.set(data, forKey: AppViewModel.citiesKey)
        }
    }

    private func loadCities() {
        guard let data = UserDefaults.standard.data(forKey: AppViewModel.citiesKey),
              let decoded = try? JSONDecoder().decode([City].self, from: data) else { return }
        cities = decoded
    }

    func saveCriteria() {
        if let data = try? JSONEncoder().encode(criteria) {
            UserDefaults.standard.set(data, forKey: AppViewModel.criteriaKey)
        }
    }

    private func loadCriteria() {
        guard let data = UserDefaults.standard.data(forKey: AppViewModel.criteriaKey),
              let decoded = try? JSONDecoder().decode(DayCriteria.self, from: data) else { return }
        criteria = decoded
    }

    func saveWindows() {
        if let data = try? JSONEncoder().encode(cachedWindows) {
            UserDefaults.standard.set(data, forKey: AppViewModel.windowsKey)
        }
    }

    private func loadWindows() {
        guard let data = UserDefaults.standard.data(forKey: AppViewModel.windowsKey),
              let decoded = try? JSONDecoder().decode([UUID:[GoodWindow]].self, from: data) else { return }
        cachedWindows = decoded
    }

    /// Delete any windows whose end‑time has passed and clear their alerts
    private func purgeExpiredWindows() {
        let now = Date()
        var toRemove: [String] = []
        for (cid, _) in cachedWindows {
            cachedWindows[cid]?.removeAll {
                if $0.to < now {
                    toRemove.append("win-\(cid)-\($0.id)")
                    return true
                }
                return false
            }
        }
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: toRemove)
    }

    


    func cacheWindows(for city: City, windows: [GoodWindow]) {
        purgeExpiredWindows()
        cachedWindows[city.id] = windows
        saveWindows()
        scheduleNotifications(for: city, windows: windows)
    }


}

// MARK: – Models
struct City: Identifiable, Codable, Hashable {
    var id        = UUID()
    var name      : String           // primary label (city / neighbourhood)
    var subtitle  : String? = nil    // secondary label (borough, admin area, etc.)
    var latitude  : Double
    var longitude : Double
}

struct DayCriteria: Codable {
    var tempMin               : Double = 65
    var tempMax               : Double = 75
    var humidityMax           : Double = 60
    var uvMax                 : Double = 8
    var cloudCoverMax: Double = 50
    var precipitationAllowed  : Bool   = false
}

struct DailyForecast: Identifiable, Codable, Hashable {
    var id                         = UUID()
    var date                       : Date
    var temperature                : Double   // average of max/min
    var humidity                   : Double
    var precipitationProbability   : Double
    var isGoodDay                  : Bool = false
    var uvMax                      : Double
}
struct HourlyForecast: Identifiable, Codable, Hashable {
    var id          = UUID()
    var time        : Date
    var temperature : Double
    var humidity    : Double
    var precipProb  : Double
    var uvIndex     : Double
    var cloudCover : Double
}
/// Continuous block where every hour meets the user’s criteria
struct GoodWindow: Identifiable, Codable, Hashable {
    let id          = UUID()
    let from        : Date
    let to          : Date
    let minTemp     : Double   // stored in °C
    let maxTemp     : Double
    let maxHumidity : Double
    let maxUV       : Double
    /// Optional user plan for this window
    var plan: String? = nil
    /// Set `true` once the user explicitly decides to skip this window
    var skipped: Bool = false
    let maxCloud : Double
}
// MARK: - GoodWindow helpers
extension GoodWindow {
    /// Return a copy of the same window but with a different time span,
    /// preserving all statistics, plan text and skipped flag.
    func copy(from newFrom: Date, to newTo: Date) -> GoodWindow {
        GoodWindow(from: newFrom,
                   to: newTo,
                   minTemp: minTemp,
                   maxTemp: maxTemp,
                   maxHumidity: maxHumidity,
                   maxUV: maxUV,
                   plan: plan,
                   skipped: skipped,
                   maxCloud: maxCloud)
    }
}

/// Wrapper used for navigation so we know which city the daily forecast belongs to
struct DailySelection: Identifiable, Hashable {
    var id          = UUID()
    var city        : City
    var daily       : DailyForecast
}

// MARK: – WeatherService (Open‑Meteo)
/// Fetches a 14‑day daily forecast and maps it into `[DailyForecast]`.
final class WeatherService {

    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session  = session
        self.decoder  = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(Self.isoDate)
    }

    func fetchForecast(for city: City) -> AnyPublisher<[DailyForecast], Error> {
        guard let url = buildURL(for: city) else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }

        return session.dataTaskPublisher(for: url)
            .map(\.data)
            .decode(type: OpenMeteoResponse.self, decoder: decoder)
            .map { $0.toDailyForecasts() }
            .eraseToAnyPublisher()
    }

    /// Fetch hourly forecast (48 h) and map to HourlyForecast
    func fetchHourly(for city: City) -> AnyPublisher<[HourlyForecast], Error> {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        comps?.queryItems = [
            .init(name: "latitude",  value: String(city.latitude)),
            .init(name: "longitude", value: String(city.longitude)),
            .init(name: "hourly",    value: "temperature_2m,relative_humidity_2m,precipitation_probability,uv_index,cloud_cover_low"),
            .init(name: "forecast_days", value: "16"),
            .init(name: "timezone",  value: "auto")
        ]
        guard let url = comps?.url else {
            return Fail(error: URLError(.badURL)).eraseToAnyPublisher()
        }

        struct HourlyResp: Decodable {
            struct Hourly: Decodable {
                let time: [Date]
                // individual points can be null, so use `[Double?]`
                let temperature_2m: [Double?]
                let relative_humidity_2m: [Double?]?
                let precipitation_probability: [Double?]?
                let uv_index: [Double?]?
                let cloud_cover_low: [Double?]?
            }
            let hourly: Hourly
        }

        return session.dataTaskPublisher(for: url)
            .map(\.data)
            .handleEvents(receiveOutput: { data in
                if let string = String(data: data, encoding: .utf8) {
                    print("[DEBUG] Raw hourly JSON:\n", string)
                }
            })
            .decode(type: HourlyResp.self, decoder: {
                let df = DateFormatter()
                df.calendar = Calendar(identifier: .gregorian)
                df.locale   = Locale(identifier: "en_US_POSIX")
                df.dateFormat = "yyyy-MM-dd'T'HH:mm"

                let dec = JSONDecoder()
                dec.dateDecodingStrategy = .formatted(df)
                return dec
            }())
            .map { resp -> [HourlyForecast] in
                let h = resp.hourly
                let count = min(h.time.count,
                                h.temperature_2m.count,
                                h.uv_index?.count ?? .max)
                var out: [HourlyForecast] = []

                for i in 0..<count {
                    // If the temperature is null, skip this hour
                    guard let temp = h.temperature_2m[i] else { continue }

                    let humidity = h.relative_humidity_2m?[safe: i] ?? nil
                    let precip   = h.precipitation_probability?[safe: i] ?? nil
                    let uv = h.uv_index?[safe:i] ?? nil
                    let cloud = h.cloud_cover_low?[safe:i] ?? nil

                    out.append(
                        HourlyForecast(
                            time: h.time[i],
                            temperature: temp,
                            humidity: humidity ?? 0,
                            precipProb: precip ?? 0,
                            uvIndex: uv ?? 0,
                            cloudCover: cloud ?? 0
                        )
                    )
                }
                return out
            }
            .eraseToAnyPublisher()
    }

    // Build the Open‑Meteo URL
    private func buildURL(for city: City) -> URL? {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        comps?.queryItems = [
            .init(name: "latitude",  value: String(city.latitude)),
            .init(name: "longitude", value: String(city.longitude)),
            .init(name: "daily", value:"temperature_2m_max,temperature_2m_min,precipitation_probability_max,relative_humidity_2m_max,uv_index_max"),
            .init(name: "forecast_days", value: "14"),
            .init(name: "timezone",  value: "auto")
        ]
        return comps?.url
    }

    /// ISO‑date formatter (yyyy‑MM‑dd)
    private static let isoDate: DateFormatter = {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale   = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    /// Fetches hourly temperature percentiles (stubbed)
    func fetchHourlyPercentiles(for city: City, window: GoodWindow) -> AnyPublisher<[HourlyPercentile], Never> {
        // TODO: implement Tomorrow.io percentiles API
        return Just([]).eraseToAnyPublisher()
    }

    // MARK: - Ensemble Fetching
    /// Fetches ensemble hourly temperature forecasts for the given city and models.
    func fetchEnsembleForecast(for city: City, models: [String]) async throws -> [WeatherApiResponse] {
        let modelParam = models.joined(separator: ",")
        guard let url = URL(string:
            "https://ensemble-api.open-meteo.com/v1/ensemble?latitude=\(city.latitude)&longitude=\(city.longitude)&hourly=temperature_2m&models=\(modelParam)&forecast_days=14&timezone=auto&format=flatbuffers"
        ) else {
            throw URLError(.badURL)
        }
        return try await WeatherApiResponse.fetch(url: url)
    }
}

// MARK: – Open‑Meteo response mapping
private struct OpenMeteoResponse: Decodable {
    struct Daily: Decodable {
        let time                           : [Date]
        let temperature_2m_max             : [Double]
        let temperature_2m_min             : [Double]
        let precipitation_probability_max  : [Double]?
        let relative_humidity_2m_max       : [Double]?
        let uv_index_max : [Double]?
    }
    let daily: Daily

    func toDailyForecasts() -> [DailyForecast] {
        let n = daily.time.count
        var out: [DailyForecast] = []
        for i in 0..<n {
            let tAvg = (daily.temperature_2m_max[i] + daily.temperature_2m_min[i]) / 2
            let precip = daily.precipitation_probability_max?[safe: i] ?? 0
            let humid  = daily.relative_humidity_2m_max?[safe: i] ?? 0
            let uv = daily.uv_index_max?[safe:i] ?? 0
            out.append(DailyForecast(date: daily.time[i],
                                     temperature: tAvg,
                                     humidity: humid,
                                     precipitationProbability: precip,
                                     uvMax: uv))
        }
        return out
    }
}

// Safe array subscript
private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: – Views
/// Represents a temperature percentile for an hourly forecast
struct HourlyPercentile: Identifiable, Decodable {
    let time: Date
    let tempP5: Double
    let tempP10: Double
    let tempP25: Double
    let median: Double
    let tempP75: Double
    let tempP90: Double
    let tempP95: Double
    var id: Date { time }
}

// 1. City List
struct CityListView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @State private var showingAdd      = false
    @State private var showingSettings = false

    var body: some View {
        List {
            ForEach(viewModel.cities) { city in
            NavigationLink(value: city) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(city.name)
                        if let sub = city.subtitle {
                            Text(sub)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
            }
            }
            .onDelete { offsets in
                viewModel.deleteCities(at: offsets)
            }
        }
        .navigationTitle("Cities")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddCityView()
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environmentObject(viewModel)
        }
    }
}

// 2. Calendar View
struct CalendarView: View {
    let city: City
    @State private var forecasts: [DailyForecast] = []
    @State private var goodWindows: [GoodWindow] = []
    @State private var isLoadingGoodWindows = true
    @EnvironmentObject var viewModel: AppViewModel
    @State private var cancellables = Set<AnyCancellable>()
    @State private var errorMessage: String?
    @State private var showSettingsSheet = false

    var body: some View {
        VStack {
            Text("Forecast for \(city.name)").font(.headline)

            List {
            // upcoming windows section (always visible)
            Section(header: Text("Upcoming Good Windows")) {
                    if isLoadingGoodWindows {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else if goodWindows.isEmpty {
                        Button {
                            showSettingsSheet = true
                        } label: {
                            HStack {
                                Text("No periods match your criteria.")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("Adjust criteria ›")
                            }
                        }
                    } else {
                        ForEach(goodWindows) { w in
                            NavigationLink(value: w) {
                                HStack {
                                    // ▶︎ Weekday + time range
                                    let wk = weekday(w.from)
                                    Text("\(wk) \(dateFmt.string(from: w.from)) → \(dateFmt.string(from: w.to))")
                                        .fontWeight(isWeekendWindow(w) ? .semibold : .regular)
                                        .foregroundColor(isWeekendWindow(w) ? .orange : .primary)
 
                                    Spacer()
 
                                    // right‑aligned stats
                                    let minT = viewModel.useCelsius ? w.minTemp : w.minTemp * 9/5 + 32
                                    let maxT = viewModel.useCelsius ? w.maxTemp : w.maxTemp * 9/5 + 32
                                    let unit = viewModel.useCelsius ? "°C" : "°F"
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("\(Int(minT))–\(Int(maxT))\(unit)")
                                            .font(.caption2).foregroundColor(.secondary)
                                        Text("≤\(Int(w.maxHumidity)) % RH")
                                            .font(.caption2).foregroundColor(.secondary)
                                        Text("≤\(Int(w.maxCloud)) % Cl")
                                            .font(.caption2).foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                // daily forecasts
                ForEach(forecasts) { f in
                    NavigationLink(value: DailySelection(city: city, daily: f)) {
                        HStack {
                            Text(f.date, style: .date)
                            Spacer()
                            let shownTemp = viewModel.useCelsius ? f.temperature
                                                                 : f.temperature * 9/5 + 32
                            Text("\(Int(shownTemp))°")
                        }
                    }
                    .listRowBackground(f.isGoodDay ? Color.green.opacity(0.25) : Color.clear)
                }
            }

            if let err = errorMessage {
                Text(err).foregroundColor(.red)
            }
        }
        .onAppear {
            // show cached windows, if any, immediately
            goodWindows = viewModel.cachedWindows[city.id] ?? []
            isLoadingGoodWindows = goodWindows.isEmpty

            viewModel.fetchForecasts(for: city)
                .sink(receiveCompletion: { result in
                    if case .failure(let err) = result {
                        errorMessage = err.localizedDescription
                    }
                }, receiveValue: { data in
                    let crit = viewModel.criteria
                    forecasts = data
                        .map { day -> DailyForecast in
                            var d = day
                            let forecastTemp = viewModel.useCelsius ? d.temperature
                                                                    : d.temperature * 9/5 + 32
                            let tempOK = forecastTemp >= crit.tempMin && forecastTemp <= crit.tempMax
                            let humidOK = d.humidity   <= crit.humidityMax
                            let rainOK  = crit.precipitationAllowed || d.precipitationProbability < 20
                            d.isGoodDay = tempOK && humidOK && rainOK
                            return d
                        }
                        .sorted {    // good days first, then chronological
                            if $0.isGoodDay == $1.isGoodDay {
                                return $0.date < $1.date
                            }
                            return $0.isGoodDay && !$1.isGoodDay
                        }
                })
                .store(in: &cancellables)

            // ---- fetch hourly to build good windows ----
            viewModel.weatherService.fetchHourly(for: city)
                .receive(on: DispatchQueue.main)
                .catch { _ in Just([]) }
                .sink { hrs in
                    // 1. Compute fresh windows from latest hourly data
                    let fresh = computeGoodWindows(from: hrs)

                    // ---- 2. Merge with persisted windows, preserving plan / skip ----
                    let previous = viewModel.cachedWindows[city.id] ?? []
 
                    func contains(_ big: GoodWindow, _ small: GoodWindow) -> Bool {
                        big.from <= small.from && big.to >= small.to
                    }
                    func sameRange(_ a: GoodWindow, _ b: GoodWindow) -> Bool {
                        abs(a.from.timeIntervalSince(b.from)) < 60 &&
                        abs(a.to.timeIntervalSince(b.to))   < 60
                    }
 
                    var merged = fresh
 
                    // copy plan/skip flags when the old window is contained in (or equal to) the new one
                    for i in merged.indices {
                        if let old = previous.first(where: { contains(merged[i], $0) || sameRange(merged[i], $0) }) {
                            merged[i].plan    = old.plan
                            merged[i].skipped = old.skipped
                        }
                    }
 
                    // bring along old planned/skipped windows that are no longer matched
                    for old in previous where
                        (old.plan != nil || old.skipped) &&
                        !merged.contains(where: { contains($0, old) || sameRange($0, old) }) {
                        merged.append(old)
                    }

                    // 3. Update UI and persist
                    goodWindows = merged
                    viewModel.cacheWindows(for: city, windows: merged)
                    isLoadingGoodWindows = false
                }
                .store(in: &cancellables)
        }
        .sheet(isPresented: $showSettingsSheet) {
            SettingsView().environmentObject(viewModel)
        }
        .navigationDestination(for: DailySelection.self) { sel in
            DayDetailView(selection: sel)
                .environmentObject(viewModel)
        }
        .navigationDestination(for: GoodWindow.self) { w in
            GoodWindowDetailView(city: city, window: w)
                .environmentObject(viewModel)
        }
    }

    /// Three‑letter weekday abbreviation (Mon, Tue, …)
    private func weekday(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "EEE"
        return df.string(from: date)
    }
 
    /// Treat as “weekend window” if:
    /// - Saturday or Sunday
    /// - Friday *and* start time is 17:00 or later
    private func isWeekendWindow(_ w: GoodWindow) -> Bool {
        let cal  = Calendar.current
        let wd   = cal.component(.weekday, from: w.from)   // 1 = Sun … 7 = Sat
        if wd == 1 || wd == 7 { return true }              // Sun / Sat
        if wd == 6 {                                       // Friday
            let hour = cal.component(.hour, from: w.from)
            return hour >= 17
        }
        if let s = viewModel.workStartHour,
           let e = viewModel.workEndHour {
            let h0 = Calendar.current.component(.hour, from: w.from)
            let h1 = Calendar.current.component(.hour, from: w.to)
            if h1 <= s || h0 >= e { return true }
        }
        return false
    }
    
    
 
    // MARK: - Good window detection
    private func computeGoodWindows(from hours: [HourlyForecast]) -> [GoodWindow] {
        guard !hours.isEmpty else { return [] }
        let c  = viewModel.criteria
        let toC = { self.viewModel.useCelsius ? $0 : ($0 - 32) * 5.0 / 9.0 }

        // hour matches criteria?
        func ok(_ h: HourlyForecast) -> Bool {
            let tC = toC(h.temperature)
            return tC >= c.tempMin && tC <= c.tempMax &&
                   h.humidity <= c.humidityMax &&
                   h.uvIndex  <= c.uvMax &&
                   h.cloudCover  <= c.cloudCoverMax &&
                   (c.precipitationAllowed || h.precipProb < 20)
        }

        var out: [GoodWindow] = []
        var start: Int? = nil

        for (i,h) in hours.enumerated() {
            if ok(h) {
                if start == nil { start = i }
            } else if let s = start {
                out.append(buildWindow(from: Array(hours[s..<i])))
                start = nil
            }
        }
        if let s = start { out.append(buildWindow(from: Array(hours[s...]))) }
        if let s = viewModel.workStartHour,
           let e = viewModel.workEndHour {
            return splitWindows(out, workStart: s, workEnd: e)
        }
        return out
    }

    private func buildWindow(from slice: [HourlyForecast]) -> GoodWindow {
        let tempsC = slice.map { viewModel.useCelsius ? $0.temperature : ($0.temperature - 32) * 5 / 9 }
        let maxUV = slice.map(\.uvIndex).max() ?? 0
        let maxCloud = slice.map(\.cloudCover).max() ?? 0

        return GoodWindow(
            from: slice.first!.time,
            to:   slice.last!.time,
            minTemp: tempsC.min() ?? 0,
            maxTemp: tempsC.max() ?? 0,
            maxHumidity: slice.map(\.humidity).max() ?? 0,
            maxUV : maxUV,
            plan: nil,
            skipped: false,
            maxCloud: maxCloud
        )
    }
    
    /// keep only the before‑work and/or after‑work pieces
    /// break any window that overlaps work hours into [before][during][after]
    private func splitWindows(_ wins: [GoodWindow],
                              workStart s: Int,
                              workEnd   e: Int) -> [GoodWindow] {

        var out: [GoodWindow] = []
        let cal = Calendar.current

        func stamp(_ ref: Date, h: Int) -> Date {
            cal.date(bySettingHour: h, minute: 0, second: 0,
                     of: cal.startOfDay(for: ref))!
        }

        for w in wins {
            let ws = stamp(w.from, h: s)   // e.g. 09:00
            let we = stamp(w.from, h: e)   // e.g. 17:00

            // window falls completely outside work hours – keep as‑is
            if w.to <= ws || w.from >= we { out.append(w); continue }

            // before‑work slice
            if w.from < ws {
                out.append(w.copy(from: w.from, to: ws))
            }

            // **** work‑hours slice (always keep) ****
            let midFrom = max(w.from, ws)
            let midTo   = min(w.to,   we)
            out.append(w.copy(from: midFrom, to: midTo))

            // after‑work slice
            if w.to > we {
                out.append(w.copy(from: we, to: w.to))
            }
        }
        return out.sorted { $0.from < $1.from }
    }

    private var dateFmt: DateFormatter {
        let df = DateFormatter()
        df.dateFormat = "MMM d, HH:mm"
        return df
    }
}

// 3. Day Detail View
struct DayDetailView: View {
    @EnvironmentObject var viewModel: AppViewModel
    let selection: DailySelection

    @State private var hours: [HourlyForecast] = []
    @State private var cancellables = Set<AnyCancellable>()

    @State private var ensembleResponses: [WeatherApiResponse] = []

    // Column headers as a computed property
    private var columnHeaders: some View {
        HStack {
            Text("Time").frame(width: 55, alignment: .leading)
            Spacer()
            Text("Temp").frame(width: 55, alignment: .trailing)
            Spacer()
            Text("RH").frame(width: 45, alignment: .trailing)
            Spacer()
            Text("Rain").frame(width: 45, alignment: .trailing)
            Spacer()
            Text("UV").frame(width: 35, alignment: .trailing)
            Spacer()
            Text("Cl").frame(width: 40, alignment: .trailing)
        }
        .font(.caption.bold())
        .foregroundColor(.secondary)
    }


    // New hourlySection computed property
    private var hourlySection: some View {
        Section(header: Text(selection.daily.date, style: .date).font(.title2)) {
            ForEach(hoursForDay()) { h in
                HStack {
                    Text(timeFormatter.string(from: h.time))
                        .frame(width: 55, alignment: .leading)
                    Spacer()
                    let shownTemp = viewModel.useCelsius ? h.temperature : h.temperature * 9/5 + 32
                    let unit = viewModel.useCelsius ? "°C" : "°F"
                    Text("\(Int(shownTemp))\(unit)")
                        .frame(width: 60, alignment: .trailing)
                    Spacer()
                    Text("\(Int(h.humidity)) %")
                        .frame(width: 50, alignment: .trailing)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(h.precipProb)) %")
                        .frame(width: 45, alignment: .trailing)
                        .foregroundColor(.blue)
                    Spacer()
                    Text(String(format: "%.1f", h.uvIndex))
                        .frame(width: 35, alignment: .trailing)
                        .foregroundColor(.purple)
                    Spacer()
                    Text("\(Int(h.cloudCover)) %")
                        .frame(width: 40, alignment: .trailing)
                        .foregroundColor(.teal)
                }
            }
        }
    }

    var body: some View {
        List {
            columnHeaders

            if hours.isEmpty {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if hoursForDay().isEmpty {
                Text("No hourly data available for this date.")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                hourlySection
                // --- Ensemble member table (single, synced horizontal scroll) ---
                Section(header:
                    Text("Ensemble Temperatures Across Members")
                        .font(.headline)
                        .padding(.bottom, 2)
                ) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if let firstResp = ensembleResponses.first,
                               let hourly     = firstResp.hourly {

                                let memberCount = hourly.variablesCount
                                let memberIndices = Array(0..<memberCount)
                                let times = hourly.getDateTime(offset: firstResp.utcOffsetSeconds)

                                // ---------- header row ----------
                                HStack(spacing: 12) {
                                    Text("Time")
                                        .frame(width: 55, alignment: .leading)
                                    ForEach(memberIndices, id: \.self) { idx in
                                        Text("\(idx)")
                                            .frame(width: 45, alignment: .trailing)
                                    }
                                }
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                                Divider()

                                // ---------- data rows ----------
                                ForEach(hoursForDay(), id: \.time) { h in
                                    HStack(spacing: 12) {
                                        Text(timeFormatter.string(from: h.time))
                                            .frame(width: 55, alignment: .leading)

                                        ForEach(memberIndices, id: \.self) { idx in
                                            let values = hourly.variables(at: idx)?.values ?? []
                                            let rawTemp = zip(times, values)
                                                .first(where: { Calendar.current.isDate($0.0,
                                                                                        equalTo: h.time,
                                                                                        toGranularity: .minute) })?.1
                                            if let t = rawTemp, t.isFinite {
                                                Text("\(Int(t))°")
                                                    .frame(width: 45, alignment: .trailing)
                                            } else {
                                                Text("—")
                                                    .frame(width: 45, alignment: .trailing)
                                            }
                                        }
                                    }
                                    Divider()
                                }
                            } else {
                                Text("No ensemble data available.")
                                    .foregroundColor(.secondary)
                                    .padding()
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                }
            }
        }
        .navigationTitle("Day Details")
        .task {
            viewModel.weatherService.fetchHourly(for: selection.city)
                .receive(on: DispatchQueue.main)
                .handleEvents(receiveSubscription: { _ in
                    print("[DEBUG] Started hourly fetch for", selection.city.name)
                }, receiveOutput: { hrs in
                    print("[DEBUG] Received", hrs.count, "hourly entries")
                }, receiveCompletion: { comp in
                    print("[DEBUG] Hourly fetch completion:", comp)
                })
                .catch { err -> Just<[HourlyForecast]> in
                    print("[DEBUG] Hourly fetch error:", err.localizedDescription)
                    return Just([])
                }
                .sink { hours = $0 }
                .store(in: &cancellables)

            // Fetch ensemble model temperatures
            Task {
                // --- Ensemble fetch for multiple candidate models ---
                let allModels = ["icon_seamless",           // DWD ICON – always works
                                 "ecmwf_ifs04",            // ECMWF 0.4°
                                 "gfs_global"]             // NOAA GFS global

                var tmpResponses: [WeatherApiResponse] = []

                for m in allModels {
                    do {
                        let res = try await viewModel.weatherService
                            .fetchEnsembleForecast(for: selection.city,
                                                   models: [m])
                        tmpResponses.append(contentsOf: res)
                    } catch {
                        // Skip models that the SDK cannot decode (e.g. schema mismatch)
                        print("Skipped model \(m) –", error)
                    }
                }
                ensembleResponses = tmpResponses
            }
        }
    }

    // Filter received 48 h list to the selected date
    private func hoursForDay() -> [HourlyForecast] {
        let cal = Calendar.current
        return hours.filter { cal.isDate($0.time, inSameDayAs: selection.daily.date) }
    }

    private var timeFormatter: DateFormatter {
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        return df
    }
}

// --- Replace Text(variable.ensembleMember) with Text("\(variable.ensembleMember)") wherever found in DayDetailView ---

// (Assumed location in an earlier ForEach block in DayDetailView, for ensemble members)
// Example of replacement:
// Before:
//   Text(variable.ensembleMember)
// After:
//   Text("\(variable.ensembleMember)")


struct GoodWindowDetailView: View {
    @EnvironmentObject var viewModel: AppViewModel
    let city: City

    @State private var hours: [HourlyForecast] = []
    @State private var cans  = Set<AnyCancellable>()
    @State private var showSettings = false
    @State private var window: GoodWindow
    // holds the API‐returned percentile distribution for this window
    @State private var percentiles: [HourlyPercentile] = []
    @State private var planText: String = ""

    init(city: City, window: GoodWindow) {
        self.city = city
        _window   = State(initialValue: window)
    }

    var body: some View {
        List {
            // column headers
            HStack {
                Text("Time").frame(width: 55, alignment: .leading)
                Spacer()
                Text("Temp").frame(width: 55, alignment: .trailing)
                Spacer()
                Text("RH").frame(width: 45, alignment: .trailing)
                Spacer()
                Text("Rain").frame(width: 45, alignment: .trailing)
                Spacer()
                Text("UV").frame(width: 35, alignment: .trailing)
                Spacer()
                Text("Cl").frame(width: 40, alignment: .trailing)
            }
            .font(.caption.bold())
            .foregroundColor(.secondary)
            Section(header: Text(title).font(.headline)) {
                ForEach(filteredHours()) { h in
                    HStack {
                        Text(timeFmt.string(from: h.time))
                            .frame(width:55,alignment:.leading)
                        Spacer()
                        let shown = viewModel.useCelsius ? h.temperature : h.temperature*9/5+32
                        let unit  = viewModel.useCelsius ? "°C":"°F"
                        Text("\(Int(shown))\(unit)")
                            .frame(width:55,alignment:.trailing)
                        Spacer()
                        Text("\(Int(h.humidity)) %")
                            .frame(width:45,alignment:.trailing)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(Int(h.precipProb)) %")
                            .frame(width:45,alignment:.trailing)
                            .foregroundColor(.blue)
                        Spacer()
                        Text(String(format: "%.1f", h.uvIndex))
                            .frame(width: 40, alignment: .trailing)
                            .foregroundColor(.purple)
                        Spacer()
                        Text("\(Int(h.cloudCover)) %")
                            .frame(width: 40, alignment: .trailing)
                            .foregroundColor(.teal)
                    }
                }
            }
            // MARK: - Temperature percentiles
            Section(header: Text("Percentiles Table (Temperature")) {
                ScrollView(.horizontal, showsIndicators: false) {
                  VStack(spacing: 0) {
                    // Header row
                    HStack {
                        Text("Time").frame(width: 55, alignment: .leading)
                        Spacer()
                        Text("5th").frame(width: 55, alignment: .trailing)
                        Spacer()
                        Text("10th").frame(width: 55, alignment: .trailing)
                        Spacer()
                        Text("25th").frame(width: 55, alignment: .trailing)
                        Spacer()
                        Text("50th").frame(width: 55, alignment: .trailing)
                        Spacer()
                        Text("75th").frame(width: 55, alignment: .trailing)
                        Spacer()
                        Text("90th").frame(width: 55, alignment: .trailing)
                        Spacer()
                        Text("95th").frame(width: 55, alignment: .trailing)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    Divider()
                    ForEach(percentiles) { p in
                        HStack {
                            Text(timeFmt.string(from: p.time))
                                .frame(width: 55, alignment: .leading)
                            Spacer()
                            Text("\(Int(p.tempP5))\(viewModel.useCelsius ? "°C" : "°F")")
                                .frame(width: 55, alignment: .trailing)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(p.tempP10))\(viewModel.useCelsius ? "°C" : "°F")")
                                .frame(width: 55, alignment: .trailing)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(p.tempP25))\(viewModel.useCelsius ? "°C" : "°F")")
                                .frame(width: 55, alignment: .trailing)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(p.median))\(viewModel.useCelsius ? "°C" : "°F")")
                                .frame(width: 55, alignment: .trailing)
                            Spacer()
                            Text("\(Int(p.tempP75))\(viewModel.useCelsius ? "°C" : "°F")")
                                .frame(width: 55, alignment: .trailing)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(p.tempP90))\(viewModel.useCelsius ? "°C" : "°F")")
                                .frame(width: 55, alignment: .trailing)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(p.tempP95))\(viewModel.useCelsius ? "°C" : "°F")")
                                .frame(width: 55, alignment: .trailing)
                                .foregroundColor(.secondary)
                        }
                        .font(.caption)
                        Divider()
                    }
                  }
                  .padding(.vertical, 4)
                }
            }
            // ---------- Plan ----------
            Section(header: Text("Plan")) {
                if window.plan == nil && !window.skipped {
                    TextField("What will you do?", text: $planText)
                        .textInputAutocapitalization(.sentences)
                    Button("Save plan") {
                        window.plan = planText.trimmingCharacters(in: .whitespacesAndNewlines)
                        persistWindow()
                    }
                    .disabled(planText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Skip this window") {
                        window.skipped = true
                        persistWindow()
                    }
                    .tint(.red)
                } else if let p = window.plan {
                    Text(p)
                    Button("Edit") {
                        planText = p
                        window.plan = nil
                    }
                } else {                // skipped
                    Text("Marked as skipped").foregroundColor(.secondary)
                    Button("Re‑activate") {
                        window.skipped = false
                        persistWindow()
                    }
                }
            }

            Button("Change criteria") { showSettings = true }
                .frame(maxWidth:.infinity,alignment:.center)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(viewModel)
        }
        .onAppear {
            // Fetch raw hourly forecasts for this city
            viewModel.weatherService.fetchHourly(for: city)
                .receive(on: DispatchQueue.main)
                .catch { _ in Just([]) }
                .sink { fetched in
                    // Store all fetched hours
                    hours = fetched
                    viewModel.weatherService
                        .fetchHourlyPercentiles(for: city, window: window)
                        .receive(on: DispatchQueue.main)
                        .sink { percentiles = $0 }
                        .store(in: &cans)
                }
                .store(in: &cans)
        }
    }

    private func persistWindow() {
        if var list = viewModel.cachedWindows[city.id],
           let idx  = list.firstIndex(where: { $0.id == window.id }) {
            list[idx] = window
            viewModel.cacheWindows(for: city, windows: list)   // ← use cacheWindows only
        }
    }

    private func filteredHours() -> [HourlyForecast] {
        hours.filter { $0.time >= window.from && $0.time <= window.to }
    }
    private var title: String {
        let df=DateFormatter(); df.dateFormat="MMM d, HH:mm"
        return "\(df.string(from: window.from)) → \(df.string(from: window.to))"
    }
    private var timeFmt: DateFormatter { let d=DateFormatter(); d.dateFormat="HH:mm"; return d }
}

// MARK: - City search view‑model (autocomplete via MapKit)
final class CitySearchViewModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query: String = "" {
        didSet { completer.queryFragment = query }
    }
    @Published var results: [MKLocalSearchCompletion] = []

    private let completer: MKLocalSearchCompleter

    override init() {
        completer = MKLocalSearchCompleter()
        super.init()
        completer.resultTypes = .address         // limit to address‑like results
        completer.delegate = self                // observe updates via delegate
    }

    /// Resolve the selected completion into a `City` and return via callback
    func select(_ completion: MKLocalSearchCompletion, completionHandler: @escaping (City) -> Void) {
        let request = MKLocalSearch.Request(completion: completion)
        let search  = MKLocalSearch(request: request)
        search.start { response, _ in
            guard let item = response?.mapItems.first else { return }
            let coord = item.placemark.coordinate
            let city  = City(
                name: completion.title,
                subtitle: completion.subtitle.isEmpty ? nil : completion.subtitle,
                latitude: coord.latitude,
                longitude: coord.longitude
            )
            DispatchQueue.main.async {
                completionHandler(city)
            }
        }
    }
    
    // MARK: - MKLocalSearchCompleterDelegate
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        DispatchQueue.main.async {
            self.results = completer.results
        }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.results = []   // clear results on error
        }
    }
}
// 4. Add City View – live autocomplete
struct AddCityView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.dismiss) var dismiss
    @StateObject private var search = CitySearchViewModel()
    
    var body: some View {
        NavigationStack {
            List {
                TextField("Search city", text: $search.query)
                    .textInputAutocapitalization(.words)
                    .disableAutocorrection(true)
                
                ForEach(search.results, id: \.self) { comp in
                    Button {
                        search.select(comp) { city in
                            viewModel.addCity(city)
                            dismiss()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(comp.title)
                            if !comp.subtitle.isEmpty {
                                Text(comp.subtitle)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add City")
        }
    }
}

// 5. Settings View – clean rows + modal wheel pickers
struct SettingsView: View {
    @EnvironmentObject var viewModel: AppViewModel

    // Which picker is currently shown
    @State private var activePicker: PickerKind?
    @State private var showLeadPicker = false
    enum PickerKind { case minTemp, maxTemp, humidity, uv, cloud, workStart, workEnd }

    var body: some View {
        Form {
            Section("Day Criteria") {
                // ---- Min Temp Row
                Button {
                    activePicker = .minTemp
                } label: {
                    HStack {
                        Text("Min Temp")
                        Spacer()
                        Text("\(Int(viewModel.criteria.tempMin))°")
                            .foregroundColor(.secondary)
                    }
                }

                // ---- Max Temp Row
                Button {
                    activePicker = .maxTemp
                } label: {
                    HStack {
                        Text("Max Temp")
                        Spacer()
                        Text("\(Int(viewModel.criteria.tempMax))°")
                            .foregroundColor(.secondary)
                    }
                }

                // ---- Max Humidity Row
                Button {
                    activePicker = .humidity
                } label: {
                    HStack {
                        Text("Max Humidity %")
                        Spacer()
                        Text("\(Int(viewModel.criteria.humidityMax)) %")
                            .foregroundColor(.secondary)
                    }
                }
                
                // -- Max UV
                Button {
                    activePicker = .uv
                } label: {
                    HStack { Text("Max UV Index"); Spacer()
                             Text("\(Int(viewModel.criteria.uvMax))")
                                 .foregroundColor(.secondary) }
                }
                
                // -- Max cloud cover
                Button { activePicker = .cloud } label: {
                    HStack { Text("Max Cloud %")
                        Spacer()
                        Text("\(Int(viewModel.criteria.cloudCoverMax)) %")
                            .foregroundColor(.secondary) }
                }

                Toggle("Allow Precipitation",
                       isOn: $viewModel.criteria.precipitationAllowed)
                    .onChange(of: viewModel.criteria.precipitationAllowed) { _ in
                        viewModel.saveCriteria()
                    }
                
                Section("Work Hours") {
                    Button {
                        activePicker = .workStart
                    } label: {
                        HStack { Text("Start"); Spacer()
                            Text(viewModel.workStartHour.map { "\($0):00" } ?? "—")
                                .foregroundColor(.secondary) }
                    }
                    Button {
                        activePicker = .workEnd
                    } label: {
                        HStack { Text("End"); Spacer()
                            Text(viewModel.workEndHour.map { "\($0):00" } ?? "—")
                                .foregroundColor(.secondary) }
                    }
                }
            }

            Section("Units") {
                Picker("Temperature Units", selection: $viewModel.useCelsius) {
                    Text("°C").tag(true)
                    Text("°F").tag(false)
                }
                .pickerStyle(.segmented)
                .onChange(of: viewModel.useCelsius) { newIsCelsius in
                    convertCriteria(toCelsius: newIsCelsius)
                }
            }
            
            Section("Notifications") {
                Toggle("Enable alerts", isOn: $viewModel.notificationsEnabled)
                ForEach(viewModel.notifyLeadHours.sorted(), id: \.self) { h in
                    HStack {
                        Text(labelForLeadHours(h))
                        Spacer()
                    }
                }
                .onDelete { indexSet in
                    viewModel.notifyLeadHours.remove(atOffsets: indexSet)
                }
                Button {
                    showLeadPicker = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("Add alert")
                    }
                }
            }
        }
        .navigationTitle("Settings")
        // ---------- modal sheet ----------
        .sheet(item: $activePicker) { kind in
            ValuePickerSheet(kind: kind)
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showLeadPicker) {
            LeadTimePickerSheet()
                .environmentObject(viewModel)
        }
    }

    // MARK: - Helpers
    /// Convert existing stored temps when user toggles unit segment
    private func convertCriteria(toCelsius: Bool) {
        if toCelsius {
            viewModel.criteria.tempMin = (viewModel.criteria.tempMin - 32) * 5 / 9
            viewModel.criteria.tempMax = (viewModel.criteria.tempMax - 32) * 5 / 9
        } else {
            viewModel.criteria.tempMin = viewModel.criteria.tempMin * 9 / 5 + 32
            viewModel.criteria.tempMax = viewModel.criteria.tempMax * 9 / 5 + 32
        }
        viewModel.saveCriteria()
    }
    
    /// Produces a nicer label for the lead‑time picker (hours → days when possible)
    private func labelForLeadHours(_ h: Int) -> String {
        if h % 24 == 0 {
            let d = h / 24
            return "Alert \(d) d before"
        } else {
            return "Alert \(h) h before"
        }
    }
}

// MARK: ValuePickerSheet – wheel picker for one value
private struct ValuePickerSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var viewModel: AppViewModel
    let kind: SettingsView.PickerKind

    @State private var tempValue: Double = 0
    @State private var humidityValue: Double = 0
    @State private var uvValue: Double = 0
    @State private var cloudValue: Double = 0
    @State private var hourValue: Double = 9

    var body: some View {
        NavigationStack {
            VStack {
                 Picker("", selection: binding) {
                    ForEach(range(), id: \.self) { v in
                        Text(label(for: v)).tag(v)
                    }
                }
                .pickerStyle(.wheel)
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        // ---- commit hour picker even if user didn't scroll ----
                        switch kind {
                        case .workStart:
                            viewModel.workStartHour = Int(hourValue)
                        case .workEnd:
                            viewModel.workEndHour   = Int(hourValue)
                        default:
                            break                 // other pickers already saved via binding
                        }
                        dismiss()
                    }
                }
            }
            .onAppear {
                switch kind {
                case .minTemp:    tempValue = viewModel.criteria.tempMin
                case .maxTemp:    tempValue = viewModel.criteria.tempMax
                case .humidity:   humidityValue = viewModel.criteria.humidityMax
                case .uv:       uvValue      = viewModel.criteria.uvMax
                case .cloud:   cloudValue = viewModel.criteria.cloudCoverMax
                case .workStart: hourValue = Double(viewModel.workStartHour ?? 9)
                case .workEnd:   hourValue = Double(viewModel.workEndHour ?? 17)
                @unknown default: break
                }
            }
        }
    }

    // Binding to the correct value
    private var binding: Binding<Double> {
        switch kind {
        case .minTemp:
            return Binding(get: { tempValue },
                           set: { new in
                               tempValue = new
                               viewModel.criteria.tempMin = new
                               viewModel.saveCriteria()
                           })
        case .maxTemp:
            return Binding(get: { tempValue },
                           set: { new in
                               tempValue = new
                               viewModel.criteria.tempMax = new
                               viewModel.saveCriteria()
                           })
        case .humidity:
            return Binding(get: { humidityValue },
                           set: { new in
                               humidityValue = new
                               viewModel.criteria.humidityMax = new
                               viewModel.saveCriteria()
                           })
        case .uv:
            return Binding(
                get: { uvValue },
                set: { new in
                    uvValue = new
                    viewModel.criteria.uvMax = new
                    viewModel.saveCriteria()
                })
            
        case .cloud:
            return Binding(get:{ cloudValue }, set:{ new in
                cloudValue = new
                viewModel.criteria.cloudCoverMax = new
                viewModel.saveCriteria()
            })
        case .workStart:
            return Binding(get:{ hourValue },
                           set:{ hourValue = $0; viewModel.workStartHour = Int($0) })
        case .workEnd:
            return Binding(get:{ hourValue },
                           set:{ hourValue = $0; viewModel.workEndHour = Int($0) })

        @unknown default:
            fatalError("Unhandled picker kind")
        
        }
    }

    // Display label for picker row
    private func label(for v: Double) -> String {
        switch kind {
        case .humidity:
            return "\(Int(v)) %"
        case .uv:       return "\(Int(v))"
        case .cloud:   return "\(Int(v)) %"
        case .workStart, .workEnd: return "\(Int(v)):00"
        default:
            return "\(Int(v))°"
        
        }
    }

    // Title text
    private var title: String {
        switch kind {
        case .minTemp:  return "Min Temp"
        case .maxTemp:  return "Max Temp"
        case .humidity: return "Max Humidity %"
        case .uv:       return "Max UV Index"
        case .cloud:   return "Max Cloud %"
        case .workStart: return "Work starts"
        case .workEnd:   return "Work ends"
        }
    }

    // Value ranges
    private func range() -> [Double] {
        switch kind {
        case .humidity:
            return Array(0...100).map { Double($0) }
        case .uv:
            return Array(0...11).map { Double($0) }
        case .cloud:   return Array(0...100).map(Double.init)
        case .workStart, .workEnd: return Array(0...23).map(Double.init)
        default:
            if viewModel.useCelsius {
                return Array(-20...40).map { Double($0) }
            } else {
                return Array(-4...104).map { Double($0) }
            }
        }
    }
}

// MARK: LeadTimePickerSheet – value + unit wheels
private struct LeadTimePickerSheet: View {

    // simple enum for hours vs. days
    enum Unit: String, CaseIterable, Identifiable {
        case hours = "h"
        case days  = "d"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var viewModel: AppViewModel

    // editable state
    @State private var value: Int = 1
    @State private var unit: Unit = .hours       // h / d
    
    

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                // two independent wheels side‑by‑side
                HStack {
                    // numeric value wheel
                    Picker("", selection: $value) {
                        ForEach(range(for: unit), id: \.self) { v in
                            Text("\(v)").tag(v)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .pickerStyle(.wheel)

                    // unit wheel
                    Picker("", selection: $unit) {
                        ForEach(Unit.allCases) { u in
                            Text(u == .hours ? "hours" : "days").tag(u)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .pickerStyle(.wheel)
                }

                // friendly preview (“Alert 3 d before” / “Alert 12 h before”)
                Text("Alert \(value) \(unit.rawValue) before")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .navigationTitle("Alert lead time")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let totalHrs = unit == .hours ? value : value * 24
                        if !viewModel.notifyLeadHours.contains(totalHrs) {
                            viewModel.notifyLeadHours.append(totalHrs)
                        }
                        dismiss()
                    }
                }
            }
        }
    }

    // helper range based on unit
    private func range(for unit: Unit) -> [Int] {
        switch unit {
        case .hours: return Array(1...23)          // 1–23 h
        case .days:  return Array(1...30)          // 1–30 d (up to a month)
        }
    }
}

// Make PickerKind identifiable for .sheet(item:)
extension SettingsView.PickerKind: Identifiable {
    var id: Int { hashValue }
}


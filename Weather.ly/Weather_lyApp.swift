//
//  Weather_lyApp.swift
//  Weather.ly
//
//  Created 2025‑04‑19
//

import Foundation
import SwiftUI
import Combine

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

    func fetchForecasts(for city: City) -> AnyPublisher<[DailyForecast], Error> {
        weatherService.fetchForecast(for: city)
    }

    // MARK: - Persistence (UserDefaults JSON)
    // inside AppViewModel
    private static let citiesKey   = "savedCities"
    private static let criteriaKey = "savedCriteria"
    private static let unitsKey    = "savedUnits"
    private static let windowsKey  = "savedWindows"

    init() {
        loadCities()
        loadCriteria()
        loadWindows()
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

    private func saveWindows() {
        if let data = try? JSONEncoder().encode(cachedWindows) {
            UserDefaults.standard.set(data, forKey: AppViewModel.windowsKey)
        }
    }

    private func loadWindows() {
        guard let data = UserDefaults.standard.data(forKey: AppViewModel.windowsKey),
              let decoded = try? JSONDecoder().decode([UUID:[GoodWindow]].self, from: data) else { return }
        cachedWindows = decoded
    }

    


    func cacheWindows(for city: City, windows: [GoodWindow]) {
        cachedWindows[city.id] = windows
        saveWindows()
    }


}

// MARK: – Models
struct City: Identifiable, Codable, Hashable {
    var id        = UUID()
    var name      : String
    var latitude  : Double
    var longitude : Double
}

struct DayCriteria: Codable {
    var tempMin               : Double = 65
    var tempMax               : Double = 75
    var humidityMax           : Double = 60
    var precipitationAllowed  : Bool   = false
}

struct DailyForecast: Identifiable, Codable, Hashable {
    var id                         = UUID()
    var date                       : Date
    var temperature                : Double   // average of max/min
    var humidity                   : Double
    var precipitationProbability   : Double
    var isGoodDay                  : Bool = false
}
struct HourlyForecast: Identifiable, Codable, Hashable {
    var id          = UUID()
    var time        : Date
    var temperature : Double
    var humidity    : Double
    var precipProb  : Double
}
/// Continuous block where every hour meets the user’s criteria
struct GoodWindow: Identifiable, Codable, Hashable {
    let id          = UUID()
    let from        : Date
    let to          : Date
    let minTemp     : Double   // stored in °C
    let maxTemp     : Double
    let maxHumidity : Double
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
            .init(name: "hourly",    value: "temperature_2m,relative_humidity_2m,precipitation_probability"),
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
                let count = min(h.time.count, h.temperature_2m.count)
                var out: [HourlyForecast] = []

                for i in 0..<count {
                    // If the temperature is null, skip this hour
                    guard let temp = h.temperature_2m[i] else { continue }

                    let humidity = h.relative_humidity_2m?[safe: i] ?? nil
                    let precip   = h.precipitation_probability?[safe: i] ?? nil

                    out.append(
                        HourlyForecast(
                            time: h.time[i],
                            temperature: temp,
                            humidity: humidity ?? 0,
                            precipProb: precip ?? 0
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
            .init(name: "daily",     value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max,relative_humidity_2m_max"),
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
}

// MARK: – Open‑Meteo response mapping
private struct OpenMeteoResponse: Decodable {
    struct Daily: Decodable {
        let time                           : [Date]
        let temperature_2m_max             : [Double]
        let temperature_2m_min             : [Double]
        let precipitation_probability_max  : [Double]?
        let relative_humidity_2m_max       : [Double]?
    }
    let daily: Daily

    func toDailyForecasts() -> [DailyForecast] {
        let n = daily.time.count
        var out: [DailyForecast] = []
        for i in 0..<n {
            let tAvg = (daily.temperature_2m_max[i] + daily.temperature_2m_min[i]) / 2
            let precip = daily.precipitation_probability_max?[safe: i] ?? 0
            let humid  = daily.relative_humidity_2m_max?[safe: i] ?? 0
            out.append(DailyForecast(date: daily.time[i],
                                     temperature: tAvg,
                                     humidity: humid,
                                     precipitationProbability: precip))
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
// 1. City List
struct CityListView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @State private var showingAdd      = false
    @State private var showingSettings = false

    var body: some View {
        List(viewModel.cities) { city in
            NavigationLink(value: city) {
                Text(city.name)
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
                        ForEach(goodWindows.prefix(6)) { w in
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
                    let wins = computeGoodWindows(from: hrs)
                    goodWindows = wins
                    viewModel.cacheWindows(for: city, windows: wins)
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
        return out
    }

    private func buildWindow(from slice: [HourlyForecast]) -> GoodWindow {
        let tempsC = slice.map { viewModel.useCelsius ? $0.temperature : ($0.temperature - 32) * 5 / 9 }
        return GoodWindow(
            from: slice.first!.time,
            to:   slice.last!.time,
            minTemp: tempsC.min() ?? 0,
            maxTemp: tempsC.max() ?? 0,
            maxHumidity: slice.map(\.humidity).max() ?? 0
        )
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
            }
            .font(.caption.bold())
            .foregroundColor(.secondary)
            if hours.isEmpty {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if hoursForDay().isEmpty {
                Text("No hourly data available for this date.")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                Section(header: Text(selection.daily.date, style: .date).font(.title2)) {
                    ForEach(hoursForDay()) { h in
                        HStack {
                            Text(timeFormatter.string(from: h.time))
                                .frame(width: 55, alignment: .leading)
                            Spacer()
                            // temperature with units
                            let shownTemp = viewModel.useCelsius ? h.temperature
                                                                 : h.temperature * 9/5 + 32
                            let unit      = viewModel.useCelsius ? "°C" : "°F"
                            Text("\(Int(shownTemp))\(unit)")
                                .frame(width: 60, alignment: .trailing)
                            Spacer()
                            Text("\(Int(h.humidity)) %")
                                .frame(width: 50, alignment: .trailing)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(h.precipProb)) %")
                                .frame(width: 50, alignment: .trailing)
                                .foregroundColor(.blue)
                        }
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

struct GoodWindowDetailView: View {
    @EnvironmentObject var viewModel: AppViewModel
    let city: City
    let window: GoodWindow

    @State private var hours: [HourlyForecast] = []
    @State private var cans  = Set<AnyCancellable>()
    @State private var showSettings = false

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
            viewModel.weatherService.fetchHourly(for: city)
                .receive(on: DispatchQueue.main)
                .catch { _ in Just([]) }
                .sink { hours = $0 }
                .store(in: &cans)
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

// 4. Add City View
// 4. Add City View  – pre‑defined list, no typing
struct AddCityView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.presentationMode) var presentation

    /// Pre‑made list of popular cities (add more as you like)
    private let sampleCities: [City] = [
        City(name: "New York",    latitude: 40.7128, longitude: -74.0060),
        City(name: "Los Angeles", latitude: 34.0522, longitude: -118.2437),
        City(name: "Chicago",     latitude: 41.8781, longitude:  -87.6298),
        City(name: "London",      latitude: 51.5074, longitude:   -0.1278),
        City(name: "Paris",       latitude: 48.8566, longitude:     2.3522),
        City(name: "Tokyo",       latitude: 35.6895, longitude:   139.6917)
    ]

    @State private var selectionIndex = 0

    var body: some View {
        NavigationStack {
            Form {
                Picker("Select a city", selection: $selectionIndex) {
                    ForEach(sampleCities.indices, id: \.self) { i in
                        Text(sampleCities[i].name).tag(i)
                    }
                }
                .pickerStyle(.wheel)
            }
            .navigationTitle("Add City")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let city = sampleCities[selectionIndex]
                        viewModel.addCity(city)
                        presentation.wrappedValue.dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { presentation.wrappedValue.dismiss() }
                }
            }
        }
    }
}

// 5. Settings View – clean rows + modal wheel pickers
struct SettingsView: View {
    @EnvironmentObject var viewModel: AppViewModel

    // Which picker is currently shown
    @State private var activePicker: PickerKind?
    enum PickerKind { case minTemp, maxTemp, humidity }

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

                Toggle("Allow Precipitation",
                       isOn: $viewModel.criteria.precipitationAllowed)
                    .onChange(of: viewModel.criteria.precipitationAllowed) { _ in
                        viewModel.saveCriteria()
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
        }
        .navigationTitle("Settings")
        // ---------- modal sheet ----------
        .sheet(item: $activePicker) { kind in
            ValuePickerSheet(kind: kind)
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
}

// MARK: ValuePickerSheet – wheel picker for one value
private struct ValuePickerSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var viewModel: AppViewModel
    let kind: SettingsView.PickerKind

    @State private var tempValue: Double = 0
    @State private var humidityValue: Double = 0

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
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                switch kind {
                case .minTemp:    tempValue = viewModel.criteria.tempMin
                case .maxTemp:    tempValue = viewModel.criteria.tempMax
                case .humidity:   humidityValue = viewModel.criteria.humidityMax
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
        }
    }

    // Display label for picker row
    private func label(for v: Double) -> String {
        switch kind {
        case .humidity:
            return "\(Int(v)) %"
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
        }
    }

    // Value ranges
    private func range() -> [Double] {
        switch kind {
        case .humidity:
            return Array(0...100).map { Double($0) }
        default:
            if viewModel.useCelsius {
                return Array(-20...40).map { Double($0) }
            } else {
                return Array(-4...104).map { Double($0) }
            }
        }
    }
}

// Make PickerKind identifiable for .sheet(item:)
extension SettingsView.PickerKind: Identifiable {
    var id: Int { hashValue }
}

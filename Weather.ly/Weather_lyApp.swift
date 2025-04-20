//
//  Weather_lyApp.swift
//  Weather.ly
//
//  Created 2025‑04‑19
//

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

    let weatherService = WeatherService()
    var cancellables   = Set<AnyCancellable>()

    func addCity(_ city: City) { cities.append(city) }

    func fetchForecasts(for city: City) -> AnyPublisher<[DailyForecast], Error> {
        weatherService.fetchForecast(for: city)
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
    @EnvironmentObject var viewModel: AppViewModel
    @State private var cancellables = Set<AnyCancellable>()
    @State private var errorMessage: String?

    var body: some View {
        VStack {
            Text("Forecast for \(city.name)").font(.headline)

            // Simple list until we build a calendar grid
            List(forecasts) { f in
                NavigationLink(value: f) {
                    HStack {
                        Text(f.date, style: .date)
                        Spacer()
                        Text("\(Int(f.temperature))°")
                    }
                }
                .listRowBackground(f.isGoodDay ? Color.green.opacity(0.25) : Color.clear)
            }

            if let err = errorMessage {
                Text(err).foregroundColor(.red)
            }
        }
        .onAppear {
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
                            let tempOK  = d.temperature >= crit.tempMin && d.temperature <= crit.tempMax
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
        }
        .navigationDestination(for: DailyForecast.self) { DayDetailView(forecast: $0) }
    }
}

// 3. Day Detail View
struct DayDetailView: View {
    let forecast: DailyForecast

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(forecast.date, style: .date).font(.title)
            Text("Avg Temp: \(Int(forecast.temperature)) °F")
            Text("Humidity: \(Int(forecast.humidity)) %")
            Text("Precip Prob: \(Int(forecast.precipitationProbability)) %")
        }
        .padding()
        .navigationTitle("Day Details")
    }
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

// 5. Settings View (criteria – not wired into UI yet)
struct SettingsView: View {
    @EnvironmentObject var viewModel: AppViewModel

    var body: some View {
        Form {
            Section("Day Criteria") {
                HStack {
                    Text("Min Temp")
                    Spacer()
                    TextField("Min", value: $viewModel.criteria.tempMin,
                              formatter: NumberFormatter())
                        .keyboardType(.decimalPad).frame(width: 60)
                }
                HStack {
                    Text("Max Temp")
                    Spacer()
                    TextField("Max", value: $viewModel.criteria.tempMax,
                              formatter: NumberFormatter())
                        .keyboardType(.decimalPad).frame(width: 60)
                }
                Toggle("Allow Precipitation", isOn: $viewModel.criteria.precipitationAllowed)
            }
        }
        .navigationTitle("Settings")
    }
}

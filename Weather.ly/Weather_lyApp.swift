// Weather.ly
// SwiftUI App Skeleton (iOS 16+ NavigationStack)

import SwiftUI
import Combine

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

// MARK: - AppViewModel
final class AppViewModel: ObservableObject {
    @Published var cities: [City] = []
    @Published var navigationPath = NavigationPath()
    @Published var criteria = DayCriteria()

    private let weatherService = WeatherService()
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Load saved cities & criteria
    }

    func addCity(_ city: City) {
        cities.append(city)
        // Persist
    }

    func fetchForecasts(for city: City) -> AnyPublisher<[DailyForecast], Error> {
        weatherService.fetchForecast(for: city)
    }
}

// MARK: - Models
struct City: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
}

struct DayCriteria: Codable {
    var tempMin: Double = 65
    var tempMax: Double = 75
    var humidityMax: Double = 60
    var precipitationAllowed: Bool = false
    // Add more criteria as needed
}

struct DailyForecast: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var date: Date
    var temperature: Double
    var humidity: Double
    var precipitationProbability: Double
    var isGoodDay: Bool = false
}

// MARK: - WeatherService
final class WeatherService {
    func fetchForecast(for city: City) -> AnyPublisher<[DailyForecast], Error> {
        // TODO: Implement API calls and aggregation
        Just([])
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }
}

// MARK: - Views

// 1. City List & Navigation via NavigationStack
struct CityListView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @State private var showingAdd = false

    var body: some View {
        List(viewModel.cities) { city in
            NavigationLink(value: city) {
                Text(city.name)
            }
        }
        .navigationTitle("Cities")
        .toolbar {
            Button(action: { showingAdd = true }) {
                Image(systemName: "plus")
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddCityView()
                .environmentObject(viewModel)
        }
    }
}

// 2. Calendar View of Forecasts
struct CalendarView: View {
    var city: City
    @State private var forecasts: [DailyForecast] = []
    @State private var cancellables = Set<AnyCancellable>()
    @EnvironmentObject var viewModel: AppViewModel
    @State private var errorMessage: String?

    var body: some View {
        VStack {
            Text("Forecast for \(city.name)")
                .font(.headline)

            // TODO: Calendar grid placeholder
            Text("Calendar placeholder")

            if let first = forecasts.first {
                NavigationLink("Details", value: first)
            }

            if let error = errorMessage {
                Text(error).foregroundColor(.red)
            }
        }
        .onAppear {
            viewModel.fetchForecasts(for: city)
                .sink(receiveCompletion: { completion in
                    if case let .failure(error) = completion {
                        errorMessage = error.localizedDescription
                    }
                }, receiveValue: { data in
                    forecasts = data
                })
                .store(in: &cancellables)
        }
        .navigationDestination(for: DailyForecast.self) { forecast in
            DayDetailView(forecast: forecast)
        }
    }
}

// 3. Day Detail View
struct DayDetailView: View {
    var forecast: DailyForecast

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Date: \(forecast.date, style: .date)")
            Text("Temp: \(Int(forecast.temperature))°F")
            Text("Humidity: \(Int(forecast.humidity))%")
            Text("Precipitation: \(Int(forecast.precipitationProbability * 100))%")
        }
        .padding()
        .navigationTitle("Day Details")
    }
}

// 4. Add City View
struct AddCityView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.presentationMode) var presentationMode
    @State private var name = ""
    @State private var lat = ""
    @State private var lon = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("City Info")) {
                    TextField("Name", text: $name)
                    TextField("Latitude", text: $lat)
                        .keyboardType(.decimalPad)
                    TextField("Longitude", text: $lon)
                        .keyboardType(.decimalPad)
                }
            }
            .navigationTitle("Add City")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let latitude = Double(lat), let longitude = Double(lon) {
                            let city = City(name: name, latitude: latitude, longitude: longitude)
                            viewModel.addCity(city)
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
    }
}

// 5. Settings View (criteria configuration)
struct SettingsView: View {
    @EnvironmentObject var viewModel: AppViewModel

    var body: some View {
        Form {
            Section(header: Text("Day Criteria")) {
                HStack {
                    Text("Min Temp")
                    Spacer()
                    TextField("Min", value: $viewModel.criteria.tempMin, formatter: NumberFormatter())
                        .keyboardType(.decimalPad)
                        .frame(width: 60)
                }
                HStack {
                    Text("Max Temp")
                    Spacer()
                    TextField("Max", value: $viewModel.criteria.tempMax, formatter: NumberFormatter())
                        .keyboardType(.decimalPad)
                        .frame(width: 60)
                }
                Toggle("Allow Precipitation", isOn: $viewModel.criteria.precipitationAllowed)
            }
        }
        .navigationTitle("Settings")
    }
}

import SwiftUI
import Combine

struct SimpleCityListView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @State private var showingAdd = false
    @State private var showingSettings = false

    var body: some View {
        List {
            ForEach(viewModel.cities) { city in
                NavigationLink(destination: SimpleForecastView(city: city)) {
                    Text(city.name)
                }
            }
            .onDelete { offsets in
                viewModel.deleteCities(at: offsets)
            }
        }
        .navigationTitle("Cities")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                Button { showingAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddCityView().environmentObject(viewModel)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView().environmentObject(viewModel)
        }
    }
}

struct SimpleForecastView: View {
    @EnvironmentObject var viewModel: AppViewModel
    let city: City

    @State private var hours: [HourlyForecast] = []
    @State private var cancellables = Set<AnyCancellable>()

    var body: some View {
        List {
            ForEach(groupByDay(hours), id: \.0) { day, dayHours in
                Section(header: Text(day, style: .date)) {
                    ColumnHeaders()
                    ForEach(dayHours) { hour in
                        hourRow(hour)
                    }
                }
            }
        }
        .navigationTitle(city.name)
        .task {
            viewModel.weatherService.fetchHourly(for: city)
                .receive(on: DispatchQueue.main)
                .sink(receiveCompletion: { _ in }, receiveValue: { hours = $0 })
                .store(in: &cancellables)
        }
    }

    private func groupByDay(_ hrs: [HourlyForecast]) -> [(Date, [HourlyForecast])] {
        let groups = Dictionary(grouping: hrs) { Calendar.current.startOfDay(for: $0.time) }
        return groups.keys.sorted().map { ($0, groups[$0]!.sorted { $0.time < $1.time }) }
    }

    @ViewBuilder
    private func hourRow(_ h: HourlyForecast) -> some View {
        let shownTemp = viewModel.useCelsius ? h.temperature : h.temperature * 9 / 5 + 32
        let unit = viewModel.useCelsius ? "°C" : "°F"

        HStack {
            Text(timeFormatter.string(from: h.time))
                .frame(width: 55, alignment: .leading)
            Spacer()
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

    private var timeFormatter: DateFormatter {
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        return df
    }

    private struct ColumnHeaders: View {
        var body: some View {
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
    }
}


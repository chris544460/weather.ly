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
                    SimpleCityCard(city: city)
                        .padding(.vertical, 4)
                }
                .listRowBackground(Color.clear)
            }
            .onDelete { offsets in
                viewModel.deleteCities(at: offsets)
            }
        }
        .listStyle(.plain)
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

struct SimpleCityCard: View {
    let city: City

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(city.name)
                    .font(.headline)
                    .foregroundColor(.white)
                Text("Forecast")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundColor(.white.opacity(0.7))
        }
        .padding()
        .background(
            LinearGradient(
                gradient: Gradient(colors: [Color.blue.opacity(0.8), Color.purple.opacity(0.8)]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct SimpleForecastView: View {
    @EnvironmentObject var viewModel: AppViewModel
    let city: City

    @State private var hours: [HourlyForecast] = []
    @State private var cancellables = Set<AnyCancellable>()
    @State private var selectedMetrics: Set<Metric> = Set(Metric.allCases)
    @State private var selectedDayIndex = 0

    enum Metric: String, CaseIterable, Identifiable {
        case temperature   = "Temp"
        case humidity      = "Humidity"
        case precipitation = "Rain"
        case uv            = "UV Index"
        case cloud         = "Clear %"

        var id: String { rawValue }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Show metrics:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack {
                        ForEach(Metric.allCases) { metric in
                            Button(action: { toggle(metric) }) {
                                Text(metric.rawValue)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .padding(6)
                                    .background(selectedMetrics.contains(metric) ? Color.accentColor.opacity(0.2) : Color.clear)
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }

            let groups = groupByDay(hours)
            if !groups.isEmpty {
                Section {
                    Picker("Date", selection: $selectedDayIndex) {
                        ForEach(groups.indices, id: \.self) { idx in
                            Text(groups[idx].0, style: .date).tag(idx)
                        }
                    }
                    .pickerStyle(.menu)
                }

                let day = groups[min(selectedDayIndex, groups.count - 1)]
                Section(header: Text(day.0, style: .date)) {
                    ColumnHeaders(metrics: selectedMetrics)
                    ForEach(day.1) { hour in
                        hourRow(hour)
                    }
                }
            }
        }
        .navigationTitle(city.name)
        .task {
            viewModel.weatherService.fetchHourly(for: city)
                .receive(on: DispatchQueue.main)
                .sink(receiveCompletion: { _ in }, receiveValue: { hrs in
                    hours = hrs
                    selectedDayIndex = 0
                })
                .store(in: &cancellables)
        }
    }

    private func groupByDay(_ hrs: [HourlyForecast]) -> [(Date, [HourlyForecast])] {
        let groups = Dictionary(grouping: hrs) { Calendar.current.startOfDay(for: $0.time) }
        return groups.keys.sorted().map { ($0, groups[$0]!.sorted { $0.time < $1.time }) }
    }

    private func toggle(_ metric: Metric) {
        if selectedMetrics.contains(metric) { selectedMetrics.remove(metric) }
        else { selectedMetrics.insert(metric) }
    }

    @ViewBuilder
    private func hourRow(_ h: HourlyForecast) -> some View {
        let shownTemp = viewModel.useCelsius ? h.temperature : h.temperature * 9 / 5 + 32
        let unit = viewModel.useCelsius ? "°C" : "°F"
        HStack {
            Text(timeFormatter.string(from: h.time))
                .frame(width: 55, alignment: .leading)
            if selectedMetrics.contains(.temperature) {
                Spacer()
                Text("\(Int(shownTemp))\(unit)")
                    .frame(width: 60, alignment: .trailing)
            }
            if selectedMetrics.contains(.humidity) {
                Spacer()
                Text("\(Int(h.humidity)) %")
                    .frame(width: 65, alignment: .trailing)
                    .foregroundColor(.secondary)
            }
            if selectedMetrics.contains(.precipitation) {
                Spacer()
                Text("\(Int(h.precipProb)) %")
                    .frame(width: 45, alignment: .trailing)
                    .foregroundColor(.blue)
            }
            if selectedMetrics.contains(.uv) {
                Spacer()
                Text(String(format: "%.1f", h.uvIndex))
                    .frame(width: 55, alignment: .trailing)
                    .foregroundColor(.purple)
            }
            if selectedMetrics.contains(.cloud) {
                Spacer()
                Text("\(Int(h.cloudCover)) %")
                    .frame(width: 55, alignment: .trailing)
                    .foregroundColor(.teal)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private var timeFormatter: DateFormatter {
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        return df
    }

    private struct ColumnHeaders: View {
        let metrics: Set<Metric>

        var body: some View {
            HStack {
                Text("Time").frame(width: 55, alignment: .leading)
                if metrics.contains(.temperature) {
                    Spacer()
                    Text("Temp").frame(width: 55, alignment: .trailing)
                }
                if metrics.contains(.humidity) {
                    Spacer()
                    Text("Humidity").frame(width: 65, alignment: .trailing)
                }
                if metrics.contains(.precipitation) {
                    Spacer()
                    Text("Rain").frame(width: 45, alignment: .trailing)
                }
                if metrics.contains(.uv) {
                    Spacer()
                    Text("UV Index").frame(width: 55, alignment: .trailing)
                }
                if metrics.contains(.cloud) {
                    Spacer()
                    Text("Clear %").frame(width: 55, alignment: .trailing)
                }
            }
            .font(.caption.bold())
            .foregroundColor(.secondary)
        }
    }
}

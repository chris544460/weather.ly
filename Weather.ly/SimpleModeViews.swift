import SwiftUI
import Combine
import OpenMeteoSdk

// MARK: - City List -----------------------------------------------------------

struct SimpleCityListView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @State private var showingAdd      = false
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
            .onDelete { viewModel.deleteCities(at: $0) }
        }
        .listStyle(.plain)
        .navigationTitle("Cities")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                Button { showingAdd      = true } label: { Image(systemName: "plus")      }
            }
        }
        .sheet(isPresented: $showingAdd)      { AddCityView().environmentObject(viewModel) }
        .sheet(isPresented: $showingSettings) { SettingsView().environmentObject(viewModel) }
    }
}

private struct SimpleCityCard: View {
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
                endPoint:   .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Forecast ------------------------------------------------------------

struct SimpleForecastView: View {
    @EnvironmentObject var viewModel: AppViewModel
    let city: City

    @State private var hours: [HourlyForecast] = []
    @State private var cancellables            = Set<AnyCancellable>()
    @State private var selectedMetrics: Set<Metric> = [.temperature]
    @State private var selectedDayIndex = 0

    // Ensemble stats
    @State private var ensembleMedian:        [Date: Double] = [:]
    @State private var ensembleLowerQuartile: [Date: Double] = [:]
    @State private var ensembleUpperQuartile: [Date: Double] = [:]

    // Metrics picker
    enum Metric: String, CaseIterable, Identifiable {
        case temperature     = "Temp"
        case humidity        = "Humidity"
        case precipitation   = "Rain"
        case uv              = "UV Index"
        case cloud           = "Clear %"
        case median          = "Median"
        case lowerQuartile   = "Lower Quartile"
        case upperQuartile   = "Upper Quartile"
        case distribution    = "Distribution"

        var id: String { rawValue }
    }

    // MARK: View
    var body: some View {
        List {
            // ───────── Metric toggles
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Show metrics:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Metric.allCases) { metric in
                                Button { toggle(metric) } label: {
                                    Text(metric.rawValue)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .fixedSize()
                                        .padding(6)
                                        .background(selectedMetrics.contains(metric)
                                                    ? Color.accentColor.opacity(0.2)
                                                    : Color.clear)
                                        .cornerRadius(6)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
            }

            // ───────── Grouped hourly data
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
        .task { fetchData() }
    }

    // MARK: - Helpers ---------------------------------------------------------

    private func fetchData() {
        // hourly
        viewModel.weatherService.fetchHourly(for: city)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { hrs in
                hours = hrs
                selectedDayIndex = 0
            })
            .store(in: &cancellables)

        // ensemble
        Task {
            do {
                let res = try await viewModel.weatherService
                    .fetchEnsembleForecast(for: city, models: ["icon_seamless"])

                if let dict = buildMedianDict(from: res) {
                    DispatchQueue.main.async { ensembleMedian = dict }
                }
                if let (lower, upper) = buildQuartileDicts(from: res) {
                    DispatchQueue.main.async {
                        ensembleLowerQuartile = lower
                        ensembleUpperQuartile = upper
                    }
                }
            } catch {
                print("Failed to fetch ensemble data:", error)
            }
        }
    }

    private func groupByDay(_ hrs: [HourlyForecast])
        -> [(Date, [HourlyForecast])] {
        let groups = Dictionary(grouping: hrs) { Calendar.current.startOfDay(for: $0.time) }
        return groups.keys.sorted().map { ($0, groups[$0]!.sorted { $0.time < $1.time }) }
    }

    private func toggle(_ metric: Metric) {
        if selectedMetrics.contains(metric) { selectedMetrics.remove(metric) }
        else                                { selectedMetrics.insert(metric)  }
    }

    // MARK: Hour row

    @ViewBuilder
    private func hourRow(_ h: HourlyForecast) -> some View {
        let shownTemp = viewModel.useCelsius ? h.temperature
                                             : h.temperature * 9 / 5 + 32
        let unit = viewModel.useCelsius ? "°C" : "°F"

        HStack {
            Text(timeFormatter.string(from: h.time))
                .frame(width: 55, alignment: .leading)

            if selectedMetrics.contains(.temperature) {
                Spacer()
                Text("\(Int(shownTemp))\(unit)")
                    .frame(width: 60, alignment: .trailing)
            }

            if selectedMetrics.contains(.median) {
                Spacer()
                let median = ensembleMedian[h.time]
                let shown  = median.map { viewModel.useCelsius ? $0 : $0 * 9 / 5 + 32 }
                Text(median != nil ? "\(Int(shown!))\(unit)" : "--")
                    .frame(width: 70, alignment: .trailing)
                    .foregroundColor(.green)
            }

            if selectedMetrics.contains(.lowerQuartile) {
                Spacer()
                let lq    = ensembleLowerQuartile[h.time]
                let shown = lq.map { viewModel.useCelsius ? $0 : $0 * 9 / 5 + 32 }
                Text(lq != nil ? "\(Int(shown!))\(unit)" : "--")
                    .frame(width: 80, alignment: .trailing)
                    .foregroundColor(.orange)
            }

            if selectedMetrics.contains(.upperQuartile) {
                Spacer()
                let uq    = ensembleUpperQuartile[h.time]
                let shown = uq.map { viewModel.useCelsius ? $0 : $0 * 9 / 5 + 32 }
                Text(uq != nil ? "\(Int(shown!))\(unit)" : "--")
                    .frame(width: 80, alignment: .trailing)
                    .foregroundColor(.pink)
            }

            if selectedMetrics.contains(.distribution) {
                Spacer()
                DistributionCurve(
                    lower:  ensembleLowerQuartile[h.time],
                    median: ensembleMedian[h.time],
                    upper:  ensembleUpperQuartile[h.time],
                    useCelsius: viewModel.useCelsius
                )
                .frame(width: 100, height: 30)
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

    // MARK: Ensemble helpers --------------------------------------------------

    private func buildMedianDict(from responses: [WeatherApiResponse])
        -> [Date: Double]? {
        guard let resp = responses.first,
              let hourly = resp.hourly else { return nil }

        let memberCount = Int(hourly.variablesCount)
        let times  = hourly.getDateTime(offset: 0)
        var all: [Date: [Double]] = [:]

        for m in 0..<memberCount {
            let vals = hourly.variables(at: Int32(m))?.values ?? []
            for (t, v) in zip(times, vals) where v.isFinite {
                all[t, default: []].append(Double(v))
            }
        }

        var medians: [Date: Double] = [:]
        for (t, vals) in all {
            let sorted = vals.sorted()
            medians[t] = sorted[sorted.count / 2]
        }
        return medians
    }

    private func buildQuartileDicts(from responses: [WeatherApiResponse])
        -> (lower: [Date: Double], upper: [Date: Double])? {
        guard let resp = responses.first,
              let hourly = resp.hourly else { return nil }

        let count = Int(hourly.variablesCount)
        let times = hourly.getDateTime(offset: 0)
        var all: [Date: [Double]] = [:]

        for m in 0..<count {
            let vals = hourly.variables(at: Int32(m))?.values ?? []
            for (t, v) in zip(times, vals) where v.isFinite {
                all[t, default: []].append(Double(v))
            }
        }

        var lowerQ: [Date: Double] = [:]
        var upperQ: [Date: Double] = [:]
        for (t, vals) in all {
            let sorted = vals.sorted()
            guard sorted.count > 1 else { continue }
            lowerQ[t] = sorted[max(0, sorted.count / 4)]
            upperQ[t] = sorted[min(sorted.count - 1, 3 * sorted.count / 4)]
        }
        return (lowerQ, upperQ)
    }

    // MARK: Column Headers ----------------------------------------------------

    private struct ColumnHeaders: View {
        let metrics: Set<Metric>

        var body: some View {
            HStack {
                Text("Time").frame(width: 55, alignment: .leading)
                if metrics.contains(.temperature)   { Spacer(); Text("Temp").frame(width: 55, alignment: .trailing) }
                if metrics.contains(.median)        { Spacer(); Text("Median").frame(width: 70, alignment: .trailing) }
                if metrics.contains(.lowerQuartile) { Spacer(); Text("Lower Q").frame(width: 80, alignment: .trailing) }
                if metrics.contains(.upperQuartile) { Spacer(); Text("Upper Q").frame(width: 80, alignment: .trailing) }
                if metrics.contains(.distribution)  { Spacer(); Text("Dist").frame(width: 100, alignment: .center) }
                if metrics.contains(.humidity)      { Spacer(); Text("Humidity").frame(width: 65, alignment: .trailing) }
                if metrics.contains(.precipitation) { Spacer(); Text("Rain").frame(width: 45, alignment: .trailing) }
                if metrics.contains(.uv)            { Spacer(); Text("UV Index").frame(width: 55, alignment: .trailing) }
                if metrics.contains(.cloud)         { Spacer(); Text("Clear %").frame(width: 55, alignment: .trailing) }
            }
            .font(.caption.bold())
            .foregroundColor(.secondary)
        }
    }
}

// MARK: - Distribution Curve --------------------------------------------------

private struct DistributionCurve: View {
    let lower: Double?
    let median: Double?
    let upper: Double?
    let useCelsius: Bool

    var body: some View {
        GeometryReader { geo in
            if let lower, let median, let upper, upper > lower {
                let centerY = geo.size.height / 2
                let ratio   = CGFloat((median - lower) / (upper - lower))
                let dotX    = geo.size.width * ratio

                let convert: (Double) -> Double = { v in
                    useCelsius ? v : v * 9 / 5 + 32
                }

                // ───── Line & dot
                Path { p in
                    p.move(to: .init(x: 0, y: centerY))
                    p.addLine(to: .init(x: geo.size.width, y: centerY))
                }
                .stroke(Color.accentColor.opacity(0.6), lineWidth: 2)

                Circle()
                    .frame(width: 6, height: 6)
                    .position(x: dotX, y: centerY)
                    .foregroundColor(.accentColor)

                // ───── Labels
                Group {
                    Text("\(Int(convert(lower)))")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                        .position(x: 0, y: centerY + 12)

                    Text("\(Int(convert(median)))")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .position(x: dotX, y: centerY - 10)

                    Text("\(Int(convert(upper)))")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                        .position(x: geo.size.width, y: centerY + 12)
                }
            }
        }
    }
}

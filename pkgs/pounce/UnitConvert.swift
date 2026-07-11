import Foundation

// MARK: - Unit conversions ("72 f in c", "10 km in mi", "1.5 gb in mb")

// Quick-answer engine for `AMOUNT UNIT in UNIT` queries. Foundation's
// Measurement/Dimension does the actual math (including non-linear scales
// like temperature), so this file is just vocabulary: alias → unit. To teach
// it a new unit, add table rows. Currency ("100 usd in eur") deliberately
// does NOT belong here — it needs live rates, i.e. its own engine reading a
// background-refreshed cache (see the contract in QuickAnswer.swift).

struct UnitConversionEngine: QuickAnswerEngine {
    func evaluate(_ query: String) -> QuickAnswer? {
        for candidate in ConversionQuery.parse(query) {
            guard let from = UnitTable.resolve(candidate.from),
                  let to = UnitTable.resolve(candidate.to),
                  // Same physical dimension only; converted(to:) traps on a
                  // cross-dimension pair ("10 km in kg").
                  type(of: from.unit) == type(of: to.unit)
            else { continue }
            let converted = Measurement(value: candidate.amount, unit: from.unit)
                .converted(to: to.unit)
            guard converted.value.isFinite else { continue }
            return QuickAnswer(
                display: "\(CalcFormat.display(converted.value, maxSignificant: 6)) \(to.unit.symbol)",
                detail: "\(CalcFormat.display(candidate.amount, maxSignificant: 6)) \(from.unit.symbol) → \(to.name)",
                icon: "ruler",
                copyText: CalcFormat.copyText(converted.value, maxSignificant: 6))
        }
        return nil
    }
}

enum UnitTable {
    struct Entry {
        let unit: Dimension
        let name: String   // human name for the detail line
    }

    // Days and up aren't in UnitDuration; linear converters extend it.
    static let day = UnitDuration(symbol: "d", converter: UnitConverterLinear(coefficient: 86_400))
    static let week = UnitDuration(symbol: "wk", converter: UnitConverterLinear(coefficient: 604_800))
    static let year = UnitDuration(symbol: "yr", converter: UnitConverterLinear(coefficient: 31_557_600)) // Julian

    private static func entry(_ unit: Dimension, _ name: String, _ aliases: [String],
                              into table: inout [String: Entry]) {
        let e = Entry(unit: unit, name: name)
        for a in aliases { table[a] = e }
    }

    static let aliases: [String: Entry] = {
        var t: [String: Entry] = [:]
        // length
        entry(UnitLength.millimeters, "millimeters", ["mm", "millimeter", "millimetre"], into: &t)
        entry(UnitLength.centimeters, "centimeters", ["cm", "centimeter", "centimetre"], into: &t)
        entry(UnitLength.meters, "meters", ["m", "meter", "metre"], into: &t)
        entry(UnitLength.kilometers, "kilometers", ["km", "kilometer", "kilometre"], into: &t)
        entry(UnitLength.inches, "inches", ["in", "inch", "inches", "\""], into: &t)
        entry(UnitLength.feet, "feet", ["ft", "foot", "feet", "'"], into: &t)
        entry(UnitLength.yards, "yards", ["yd", "yard"], into: &t)
        entry(UnitLength.miles, "miles", ["mi", "mile"], into: &t)
        entry(UnitLength.nauticalMiles, "nautical miles", ["nmi", "nautical mile"], into: &t)
        // mass
        entry(UnitMass.milligrams, "milligrams", ["mg", "milligram"], into: &t)
        entry(UnitMass.grams, "grams", ["g", "gram"], into: &t)
        entry(UnitMass.kilograms, "kilograms", ["kg", "kilo", "kilogram"], into: &t)
        entry(UnitMass.metricTons, "metric tons", ["t", "ton", "tonne"], into: &t)
        entry(UnitMass.ounces, "ounces", ["oz", "ounce"], into: &t)
        entry(UnitMass.pounds, "pounds", ["lb", "lbs", "pound"], into: &t)
        entry(UnitMass.stones, "stones", ["st", "stone"], into: &t)
        // temperature
        entry(UnitTemperature.celsius, "Celsius", ["c", "celsius", "centigrade"], into: &t)
        entry(UnitTemperature.fahrenheit, "Fahrenheit", ["f", "fahrenheit"], into: &t)
        entry(UnitTemperature.kelvin, "Kelvin", ["k", "kelvin"], into: &t)
        // volume
        entry(UnitVolume.milliliters, "milliliters", ["ml", "milliliter", "millilitre"], into: &t)
        entry(UnitVolume.centiliters, "centiliters", ["cl", "centiliter"], into: &t)
        entry(UnitVolume.liters, "liters", ["l", "liter", "litre"], into: &t)
        entry(UnitVolume.gallons, "gallons", ["gal", "gallon"], into: &t)
        entry(UnitVolume.quarts, "quarts", ["qt", "quart"], into: &t)
        entry(UnitVolume.pints, "pints", ["pt", "pint"], into: &t)
        entry(UnitVolume.cups, "cups", ["cup"], into: &t)
        entry(UnitVolume.fluidOunces, "fluid ounces", ["floz", "fl oz", "fluid ounce"], into: &t)
        entry(UnitVolume.tablespoons, "tablespoons", ["tbsp", "tablespoon"], into: &t)
        entry(UnitVolume.teaspoons, "teaspoons", ["tsp", "teaspoon"], into: &t)
        // speed
        entry(UnitSpeed.kilometersPerHour, "km/h", ["kmh", "kph", "km/h"], into: &t)
        entry(UnitSpeed.milesPerHour, "mph", ["mph"], into: &t)
        entry(UnitSpeed.metersPerSecond, "m/s", ["m/s", "mps"], into: &t)
        entry(UnitSpeed.knots, "knots", ["kn", "knot"], into: &t)
        // duration
        entry(UnitDuration.milliseconds, "milliseconds", ["ms", "millisecond"], into: &t)
        entry(UnitDuration.seconds, "seconds", ["s", "sec", "second"], into: &t)
        entry(UnitDuration.minutes, "minutes", ["min", "minute"], into: &t)
        entry(UnitDuration.hours, "hours", ["h", "hr", "hour"], into: &t)
        entry(day, "days", ["d", "day"], into: &t)
        entry(week, "weeks", ["wk", "week"], into: &t)
        entry(year, "years", ["yr", "year"], into: &t)
        // information (decimal like Finder; *ib for binary)
        entry(UnitInformationStorage.bits, "bits", ["bit"], into: &t)
        entry(UnitInformationStorage.bytes, "bytes", ["b", "byte"], into: &t)
        entry(UnitInformationStorage.kilobytes, "kilobytes", ["kb", "kilobyte"], into: &t)
        entry(UnitInformationStorage.megabytes, "megabytes", ["mb", "megabyte"], into: &t)
        entry(UnitInformationStorage.gigabytes, "gigabytes", ["gb", "gigabyte"], into: &t)
        entry(UnitInformationStorage.terabytes, "terabytes", ["tb", "terabyte"], into: &t)
        entry(UnitInformationStorage.petabytes, "petabytes", ["pb", "petabyte"], into: &t)
        entry(UnitInformationStorage.kibibytes, "kibibytes", ["kib", "kibibyte"], into: &t)
        entry(UnitInformationStorage.mebibytes, "mebibytes", ["mib", "mebibyte"], into: &t)
        entry(UnitInformationStorage.gibibytes, "gibibytes", ["gib", "gibibyte"], into: &t)
        entry(UnitInformationStorage.tebibytes, "tebibytes", ["tib", "tebibyte"], into: &t)
        // area
        entry(UnitArea.squareMeters, "square meters", ["m2", "sqm", "square meter"], into: &t)
        entry(UnitArea.squareKilometers, "square kilometers", ["km2", "square kilometer"], into: &t)
        entry(UnitArea.squareFeet, "square feet", ["ft2", "sqft", "sq ft", "square foot", "square feet"], into: &t)
        entry(UnitArea.squareMiles, "square miles", ["mi2", "square mile"], into: &t)
        entry(UnitArea.acres, "acres", ["ac", "acre"], into: &t)
        entry(UnitArea.hectares, "hectares", ["ha", "hectare"], into: &t)
        // energy
        entry(UnitEnergy.joules, "joules", ["j", "joule"], into: &t)
        entry(UnitEnergy.kilojoules, "kilojoules", ["kj", "kilojoule"], into: &t)
        entry(UnitEnergy.calories, "calories", ["cal", "calorie"], into: &t)
        entry(UnitEnergy.kilocalories, "kilocalories", ["kcal", "kilocalorie"], into: &t)
        entry(UnitEnergy.kilowattHours, "kilowatt-hours", ["kwh", "kilowatt hour"], into: &t)
        // angle
        entry(UnitAngle.degrees, "degrees", ["deg", "degree", "°"], into: &t)
        entry(UnitAngle.radians, "radians", ["rad", "radian"], into: &t)
        return t
    }()

    // Tokens arrive lowercased/single-spaced from ConversionQuery. Try the
    // exact spelling, then strip a plural "s"/"es" and a "°" prefix.
    static func resolve(_ raw: String) -> Entry? {
        var token = raw
        if token.hasPrefix("°") { token = String(token.dropFirst()) }
        if let hit = aliases[token] { return hit }
        if token.hasSuffix("es"), let hit = aliases[String(token.dropLast(2))] { return hit }
        if token.hasSuffix("s"), let hit = aliases[String(token.dropLast())] { return hit }
        return nil
    }
}

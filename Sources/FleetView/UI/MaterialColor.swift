import Foundation

/// Material 3 colour from a seed, in Swift: HCT, tonal palettes, and the scheme FleetView draws with.
///
/// A port of the parts of Google's material-color-utilities 0.3.0 (Apache 2.0) that `SchemeTonalSpot`
/// needs — the same version the website's seed picker was generated with, so a seed gives the app
/// and the site the same M3 roles to the byte. Only HCT and `TonalPalette` are ported, not the
/// DynamicColor engine: at standard contrast every TonalSpot role in 0.3.0 is a fixed tone of one
/// palette (checked against the library over 2000 random seeds, both appearances, every role used
/// here — no exceptions), so the engine's contrast solving never moves a tone and would only be
/// dead weight. If a role or a contrast level outside that is ever wanted, re-check that claim first.
///
/// Foundation only, so it can be compiled on its own next to the JS library to compare outputs.
enum MaterialColor {

    // MARK: HCT

    /// Hue, chroma and tone of an sRGB colour (CAM16 hue/chroma under the default viewing
    /// conditions, L* tone).
    struct Hct {
        let hue: Double
        let chroma: Double
        let tone: Double

        init(argb: UInt32) {
            let cam = Cam16(argb: argb)
            hue = cam.hue
            chroma = cam.chroma
            tone = Color.lstar(argb)
        }
    }

    /// The colour with this hue, chroma and tone — or, when that chroma is out of gamut, the most
    /// chromatic one with the same hue and tone.
    static func argb(hue: Double, chroma: Double, tone: Double) -> UInt32 {
        Solver.solveToInt(hue, chroma, tone)
    }

    /// `Blend.harmonize`: turn a fixed colour (here "needs you" amber) a little toward the seed, at
    /// most 15°, so it sits in the scheme instead of next to it.
    static func harmonize(_ design: UInt32, toward source: UInt32) -> UInt32 {
        let from = Hct(argb: design), to = Hct(argb: source)
        let difference = Math.differenceDegrees(from.hue, to.hue)
        let rotation = min(difference * 0.5, 15.0)
        let hue = Math.sanitizeDegrees(from.hue + rotation * Math.rotationDirection(from.hue, to.hue))
        return argb(hue: hue, chroma: from.chroma, tone: from.tone)
    }

    /// Every tone of one hue and chroma.
    struct TonalPalette {
        let hue: Double
        let chroma: Double
        func tone(_ t: Double) -> UInt32 { MaterialColor.argb(hue: hue, chroma: chroma, tone: t) }
    }

    // MARK: math_utils

    enum Math {
        static func signum(_ x: Double) -> Double { x < 0 ? -1 : (x == 0 ? 0 : 1) }
        static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { (1.0 - t) * a + t * b }
        static func sanitizeDegrees(_ d: Double) -> Double {
            let r = d.truncatingRemainder(dividingBy: 360.0)
            return r < 0 ? r + 360.0 : r
        }
        static func rotationDirection(_ from: Double, _ to: Double) -> Double {
            sanitizeDegrees(to - from) <= 180.0 ? 1.0 : -1.0
        }
        static func differenceDegrees(_ a: Double, _ b: Double) -> Double {
            180.0 - abs(abs(a - b) - 180.0)
        }
        static func multiply(_ row: [Double], _ m: [[Double]]) -> [Double] {
            [row[0] * m[0][0] + row[1] * m[0][1] + row[2] * m[0][2],
             row[0] * m[1][0] + row[1] * m[1][1] + row[2] * m[1][2],
             row[0] * m[2][0] + row[1] * m[2][1] + row[2] * m[2][2]]
        }
    }

    // MARK: color_utils

    enum Color {
        static func argb(_ r: Int, _ g: Int, _ b: Int) -> UInt32 {
            0xFF00_0000 | UInt32(r & 255) << 16 | UInt32(g & 255) << 8 | UInt32(b & 255)
        }
        static func argb(linrgb: [Double]) -> UInt32 {
            argb(delinearized(linrgb[0]), delinearized(linrgb[1]), delinearized(linrgb[2]))
        }
        static func argb(lstar: Double) -> UInt32 {
            let c = delinearized(yFromLstar(lstar))
            return argb(c, c, c)
        }
        static func lstar(_ argb: UInt32) -> Double {
            let y = 0.2126 * linearized(Int(argb >> 16 & 255)) + 0.7152 * linearized(Int(argb >> 8 & 255))
                + 0.0722 * linearized(Int(argb & 255))
            return 116.0 * labF(y / 100.0) - 16.0
        }
        static func yFromLstar(_ lstar: Double) -> Double { 100.0 * labInvf((lstar + 16.0) / 116.0) }
        static func linearized(_ component: Int) -> Double {
            let n = Double(component) / 255.0
            return n <= 0.040449936 ? n / 12.92 * 100.0 : pow((n + 0.055) / 1.055, 2.4) * 100.0
        }
        static func delinearized(_ component: Double) -> Int {
            let n = component / 100.0
            let d = n <= 0.0031308 ? n * 12.92 : 1.055 * pow(n, 1.0 / 2.4) - 0.055
            // JS Math.round: half rounds up. Only differs from Swift's rounding below zero, which the
            // clamp throws away anyway.
            return min(255, max(0, Int((d * 255.0 + 0.5).rounded(.down))))
        }
        static func labF(_ t: Double) -> Double {
            let e = 216.0 / 24389.0, kappa = 24389.0 / 27.0
            return t > e ? pow(t, 1.0 / 3.0) : (kappa * t + 16) / 116
        }
        static func labInvf(_ ft: Double) -> Double {
            let e = 216.0 / 24389.0, kappa = 24389.0 / 27.0
            let ft3 = ft * ft * ft
            return ft3 > e ? ft3 : (116 * ft - 16) / kappa
        }
    }

    // MARK: viewing_conditions (the default ones only)

    struct ViewingConditions {
        let n, aw, nbb, ncb, c, nc, fl, fLRoot, z: Double
        let rgbD: [Double]

        static let standard: ViewingConditions = {
            let white = [95.047, 100.0, 108.883]
            let adaptingLuminance = (200.0 / Double.pi) * Color.yFromLstar(50.0) / 100.0
            let backgroundLstar = 50.0, surround = 2.0
            let rW = white[0] * 0.401288 + white[1] * 0.650173 + white[2] * -0.051461
            let gW = white[0] * -0.250268 + white[1] * 1.204414 + white[2] * 0.045854
            let bW = white[0] * -0.002079 + white[1] * 0.048952 + white[2] * 0.953127
            let f = 0.8 + surround / 10.0
            // The library's `f >= 0.9` branch; with the default surround (2.0) f is 1.0, so the other
            // branch can never run here.
            let c = Math.lerp(0.59, 0.69, (f - 0.9) * 10.0)
            var d = f * (1.0 - (1.0 / 3.6) * exp((-adaptingLuminance - 42.0) / 92.0))
            d = d > 1.0 ? 1.0 : (d < 0.0 ? 0.0 : d)
            let rgbD = [d * (100.0 / rW) + 1.0 - d, d * (100.0 / gW) + 1.0 - d, d * (100.0 / bW) + 1.0 - d]
            let k = 1.0 / (5.0 * adaptingLuminance + 1.0)
            let k4 = k * k * k * k, k4F = 1.0 - k4
            let fl = k4 * adaptingLuminance + 0.1 * k4F * k4F * cbrt(5.0 * adaptingLuminance)
            let n = Color.yFromLstar(backgroundLstar) / white[1]
            let z = 1.48 + sqrt(n)
            let nbb = 0.725 / pow(n, 0.2)
            let factors = [pow(fl * rgbD[0] * rW / 100.0, 0.42), pow(fl * rgbD[1] * gW / 100.0, 0.42),
                           pow(fl * rgbD[2] * bW / 100.0, 0.42)]
            let rgbA = factors.map { 400.0 * $0 / ($0 + 27.13) }
            let aw = (2.0 * rgbA[0] + rgbA[1] + 0.05 * rgbA[2]) * nbb
            return ViewingConditions(n: n, aw: aw, nbb: nbb, ncb: nbb, c: c, nc: f, fl: fl,
                                     fLRoot: pow(fl, 0.25), z: z, rgbD: rgbD)
        }()
    }

    // MARK: cam16 (hue and chroma of a colour)

    struct Cam16 {
        let hue: Double
        let chroma: Double

        init(argb: UInt32) {
            let vc = ViewingConditions.standard
            let redL = Color.linearized(Int(argb >> 16 & 255))
            let greenL = Color.linearized(Int(argb >> 8 & 255))
            let blueL = Color.linearized(Int(argb & 255))
            let x = 0.41233895 * redL + 0.35762064 * greenL + 0.18051042 * blueL
            let y = 0.2126 * redL + 0.7152 * greenL + 0.0722 * blueL
            let z = 0.01932141 * redL + 0.11916382 * greenL + 0.95034478 * blueL
            let rC = 0.401288 * x + 0.650173 * y - 0.051461 * z
            let gC = -0.250268 * x + 1.204414 * y + 0.045854 * z
            let bC = -0.002079 * x + 0.048952 * y + 0.953127 * z
            let rD = vc.rgbD[0] * rC, gD = vc.rgbD[1] * gC, bD = vc.rgbD[2] * bC
            let rAF = pow(vc.fl * abs(rD) / 100.0, 0.42)
            let gAF = pow(vc.fl * abs(gD) / 100.0, 0.42)
            let bAF = pow(vc.fl * abs(bD) / 100.0, 0.42)
            let rA = Math.signum(rD) * 400.0 * rAF / (rAF + 27.13)
            let gA = Math.signum(gD) * 400.0 * gAF / (gAF + 27.13)
            let bA = Math.signum(bD) * 400.0 * bAF / (bAF + 27.13)
            let a = (11.0 * rA + -12.0 * gA + bA) / 11.0
            let b = (rA + gA - 2.0 * bA) / 9.0
            let u = (20.0 * rA + 20.0 * gA + 21.0 * bA) / 20.0
            let p2 = (40.0 * rA + 20.0 * gA + bA) / 20.0
            let atanDegrees = atan2(b, a) * 180.0 / Double.pi
            let hue = atanDegrees < 0 ? atanDegrees + 360.0 : (atanDegrees >= 360 ? atanDegrees - 360.0 : atanDegrees)
            let ac = p2 * vc.nbb
            let j = 100.0 * pow(ac / vc.aw, vc.c * vc.z)
            let huePrime = hue < 20.14 ? hue + 360 : hue
            let eHue = 0.25 * (cos(huePrime * Double.pi / 180.0 + 2.0) + 3.8)
            let p1 = 50000.0 / 13.0 * eHue * vc.nc * vc.ncb
            let t = p1 * sqrt(a * a + b * b) / (u + 0.305)
            let alpha = pow(t, 0.9) * pow(1.64 - pow(0.29, vc.n), 0.73)
            self.hue = hue
            self.chroma = alpha * sqrt(j / 100.0)
        }
    }

    // MARK: hct_solver

    enum Solver {
        static let scaledDiscountFromLinrgb: [[Double]] = [[0.001200833568784504, 0.002389694492170889, 0.0002795742885861124],
             [0.0005891086651375999, 0.0029785502573438758, 0.0003270666104008398],
             [0.00010146692491640572, 0.0005364214359186694, 0.0032979401770712076]]
        static let linrgbFromScaledDiscount: [[Double]] = [[1373.2198709594231, -1100.4251190754821, -7.278681089101213],
             [-271.815969077903, 559.6580465940733, -32.46047482791194],
             [1.9622899599665666, -57.173814538844006, 308.7233197812385]]
        static let yFromLinrgb: [Double] = [0.2126, 0.7152, 0.0722]
        static let criticalPlanes: [Double] = [
            0.015176349177441876, 0.045529047532325624, 0.07588174588720938, 0.10623444424209313,
            0.13658714259697685, 0.16693984095186062, 0.19729253930674434, 0.2276452376616281,
            0.2579979360165119, 0.28835063437139563, 0.3188300904430532, 0.350925934958123,
            0.3848314933096426, 0.42057480301049466, 0.458183274052838, 0.4976837250274023,
            0.5391024159806381, 0.5824650784040898, 0.6277969426914107, 0.6751227633498623,
            0.7244668422128921, 0.775853049866786, 0.829304845476233, 0.8848452951698498,
            0.942497089126609, 1.0022825574869039, 1.0642236851973577, 1.1283421258858297,
            1.1946592148522128, 1.2631959812511864, 1.3339731595349034, 1.407011200216447,
            1.4823302800086415, 1.5599503113873272, 1.6398909516233677, 1.7221716113234105,
            1.8068114625156377, 1.8938294463134073, 1.9832442801866852, 2.075074464868551,
            2.1693382909216234, 2.2660538449872063, 2.36523901573795, 2.4669114995532007,
            2.5710888059345764, 2.6777882626779785, 2.7870270208169257, 2.898822059350997,
            3.0131901897720907, 3.1301480604002863, 3.2497121605402226, 3.3718988244681087,
            3.4967242352587946, 3.624204428461639, 3.754355295633311, 3.887192587735158,
            4.022731918402185, 4.160988767090289, 4.301978482107941, 4.445716283538092,
            4.592217266055746, 4.741496401646282, 4.893568542229298, 5.048448422192488,
            5.20615066083972, 5.3666897647573375, 5.5300801301023865, 5.696336044816294,
            5.865471690767354, 6.037501145825082, 6.212438385869475, 6.390297286737924,
            6.571091626112461, 6.7548350853498045, 6.941541251256611, 7.131223617812143,
            7.323895587840543, 7.5195704746346665, 7.7182615035334345, 7.919981813454504,
            8.124744458384042, 8.332562408825165, 8.543448553206703, 8.757415699253682,
            8.974476575321063, 9.194643831691977, 9.417930041841839, 9.644347703669503,
            9.873909240696694, 10.106627003236781, 10.342513269534024, 10.58158024687427,
            10.8238400726681, 11.069304815507364, 11.317986476196008, 11.569896988756009,
            11.825048221409341, 12.083451977536606, 12.345119996613247, 12.610063955123938,
            12.878295467455942, 13.149826086772048, 13.42466730586372, 13.702830557985108,
            13.984327217668513, 14.269168601521828, 14.55736596900856, 14.848930523210871,
            15.143873411576273, 15.44220572664832, 15.743938506781891, 16.04908273684337,
            16.35764934889634, 16.66964922287304, 16.985093187232053, 17.30399201960269,
            17.62635644741625, 17.95219714852476, 18.281524751807332, 18.614349837764564,
            18.95068293910138, 19.290534541298456, 19.633915083172692, 19.98083495742689,
            20.331304511189067, 20.685334046541502, 21.042933821039977, 21.404114048223256,
            21.76888489811322, 22.137256497705877, 22.50923893145328, 22.884842241736916,
            23.264076429332462, 23.6469514538663, 24.033477234264016, 24.42366364919083,
            24.817520537484558, 25.21505769858089, 25.61628489293138, 26.021211842414342,
            26.429848230738664, 26.842203703840827, 27.258287870275353, 27.678110301598522,
            28.10168053274597, 28.529008062403893, 28.96010235337422, 29.39497283293396,
            29.83362889318845, 30.276079891419332, 30.722335150426627, 31.172403958865512,
            31.62629557157785, 32.08401920991837, 32.54558406207592, 33.010999283389665,
            33.4802739966603, 33.953417292456834, 34.430438229418264, 34.911345834551085,
            35.39614910352207, 35.88485700094671, 36.37747846067349, 36.87402238606382,
            37.37449765026789, 37.87891309649659, 38.38727753828926, 38.89959975977785,
            39.41588851594697, 39.93615253289054, 40.460400508064545, 40.98864111053629,
            41.520882981230194, 42.05713473317016, 42.597404951718396, 43.141702194811224,
            43.6900349931913, 44.24241185063697, 44.798841244188324, 45.35933162437017,
            45.92389141541209, 46.49252901546552, 47.065252796817916, 47.64207110610409,
            48.22299226451468, 48.808024568002054, 49.3971762874833, 49.9904556690408,
            50.587870934119984, 51.189430279724725, 51.79514187861014, 52.40501387947288,
            53.0190544071392, 53.637271562750364, 54.259673423945976, 54.88626804504493,
            55.517063457223934, 56.15206766869424, 56.79128866487574, 57.43473440856916,
            58.08241284012621, 58.734331877617365, 59.39049941699807, 60.05092333227251,
            60.715611475655585, 61.38457167773311, 62.057811747619894, 62.7353394731159,
            63.417162620860914, 64.10328893648692, 64.79372614476921, 65.48848194977529,
            66.18756403501224, 66.89098006357258, 67.59873767827808, 68.31084450182222,
            69.02730813691093, 69.74813616640164, 70.47333615344107, 71.20291564160104,
            71.93688215501312, 72.67524319850172, 73.41800625771542, 74.16517879925733,
            74.9167682708136, 75.67278210128072, 76.43322770089146, 77.1981124613393,
            77.96744375590167, 78.74122893956174, 79.51947534912904, 80.30219030335869,
            81.08938110306934, 81.88105503125999, 82.67721935322541, 83.4778813166706,
            84.28304815182372, 85.09272707154808, 85.90692527145302, 86.72564993000343,
            87.54890820862819, 88.3767072518277, 89.2090541872801, 90.04595612594655,
            90.88742016217518, 91.73345337380438, 92.58406282226491, 93.43925555268066,
            94.29903859396902, 95.16341895893969, 96.03240364439274, 96.9059996312159,
            97.78421388448044, 98.6670533535366, 99.55452497210776]

        static func sanitizeRadians(_ angle: Double) -> Double {
            (angle + Double.pi * 8).truncatingRemainder(dividingBy: Double.pi * 2)
        }
        static func trueDelinearized(_ component: Double) -> Double {
            let n = component / 100.0
            return (n <= 0.0031308 ? n * 12.92 : 1.055 * pow(n, 1.0 / 2.4) - 0.055) * 255.0
        }
        static func chromaticAdaptation(_ component: Double) -> Double {
            let af = pow(abs(component), 0.42)
            return Math.signum(component) * 400.0 * af / (af + 27.13)
        }
        static func hueOf(_ linrgb: [Double]) -> Double {
            let s = Math.multiply(linrgb, scaledDiscountFromLinrgb)
            let rA = chromaticAdaptation(s[0]), gA = chromaticAdaptation(s[1]), bA = chromaticAdaptation(s[2])
            let a = (11.0 * rA + -12.0 * gA + bA) / 11.0
            let b = (rA + gA - 2.0 * bA) / 9.0
            return atan2(b, a)
        }
        static func areInCyclicOrder(_ a: Double, _ b: Double, _ c: Double) -> Bool {
            sanitizeRadians(b - a) < sanitizeRadians(c - a)
        }
        static func setCoordinate(_ source: [Double], _ coordinate: Double, _ target: [Double], _ axis: Int) -> [Double] {
            let t = (coordinate - source[axis]) / (target[axis] - source[axis])
            return [source[0] + (target[0] - source[0]) * t, source[1] + (target[1] - source[1]) * t,
                    source[2] + (target[2] - source[2]) * t]
        }
        static func isBounded(_ x: Double) -> Bool { 0.0 <= x && x <= 100.0 }
        static func nthVertex(_ y: Double, _ n: Int) -> [Double] {
            let kR = yFromLinrgb[0], kG = yFromLinrgb[1], kB = yFromLinrgb[2]
            let coordA = n % 4 <= 1 ? 0.0 : 100.0
            let coordB = n % 2 == 0 ? 0.0 : 100.0
            let none = [-1.0, -1.0, -1.0]
            if n < 4 {
                let g = coordA, b = coordB, r = (y - g * kG - b * kB) / kR
                return isBounded(r) ? [r, g, b] : none
            } else if n < 8 {
                let b = coordA, r = coordB, g = (y - r * kR - b * kB) / kG
                return isBounded(g) ? [r, g, b] : none
            } else {
                let r = coordA, g = coordB, b = (y - r * kR - g * kG) / kB
                return isBounded(b) ? [r, g, b] : none
            }
        }
        static func bisectToSegment(_ y: Double, _ targetHue: Double) -> ([Double], [Double]) {
            var left = [-1.0, -1.0, -1.0], right = left
            var leftHue = 0.0, rightHue = 0.0
            var initialized = false, uncut = true
            for n in 0..<12 {
                let mid = nthVertex(y, n)
                if mid[0] < 0 { continue }
                let midHue = hueOf(mid)
                if !initialized {
                    left = mid; right = mid; leftHue = midHue; rightHue = midHue
                    initialized = true
                    continue
                }
                if uncut || areInCyclicOrder(leftHue, midHue, rightHue) {
                    uncut = false
                    if areInCyclicOrder(leftHue, targetHue, midHue) {
                        right = mid; rightHue = midHue
                    } else {
                        left = mid; leftHue = midHue
                    }
                }
            }
            return (left, right)
        }
        static func bisectToLimit(_ y: Double, _ targetHue: Double) -> [Double] {
            var (left, right) = bisectToSegment(y, targetHue)
            var leftHue = hueOf(left)
            for axis in 0..<3 where left[axis] != right[axis] {
                var lPlane = -1, rPlane = 255
                if left[axis] < right[axis] {
                    lPlane = Int(floor(trueDelinearized(left[axis]) - 0.5))
                    rPlane = Int(ceil(trueDelinearized(right[axis]) - 0.5))
                } else {
                    lPlane = Int(ceil(trueDelinearized(left[axis]) - 0.5))
                    rPlane = Int(floor(trueDelinearized(right[axis]) - 0.5))
                }
                for _ in 0..<8 {
                    if abs(rPlane - lPlane) <= 1 { break }
                    let mPlane = Int(floor(Double(lPlane + rPlane) / 2.0))
                    let mid = setCoordinate(left, criticalPlanes[mPlane], right, axis)
                    let midHue = hueOf(mid)
                    if areInCyclicOrder(leftHue, targetHue, midHue) {
                        right = mid; rPlane = mPlane
                    } else {
                        left = mid; leftHue = midHue; lPlane = mPlane
                    }
                }
            }
            return [(left[0] + right[0]) / 2, (left[1] + right[1]) / 2, (left[2] + right[2]) / 2]
        }
        static func inverseChromaticAdaptation(_ adapted: Double) -> Double {
            let a = abs(adapted)
            let base = max(0, 27.13 * a / (400.0 - a))
            return Math.signum(adapted) * pow(base, 1.0 / 0.42)
        }
        static func findResultByJ(_ hueRadians: Double, _ chroma: Double, _ y: Double) -> UInt32 {
            var j = sqrt(y) * 11.0
            let vc = ViewingConditions.standard
            let tInnerCoeff = 1 / pow(1.64 - pow(0.29, vc.n), 0.73)
            let eHue = 0.25 * (cos(hueRadians + 2.0) + 3.8)
            let p1 = eHue * (50000.0 / 13.0) * vc.nc * vc.ncb
            let hSin = sin(hueRadians), hCos = cos(hueRadians)
            for round in 0..<5 {
                let jNormalized = j / 100.0
                let alpha = chroma == 0.0 || j == 0.0 ? 0.0 : chroma / sqrt(jNormalized)
                let t = pow(alpha * tInnerCoeff, 1.0 / 0.9)
                let ac = vc.aw * pow(jNormalized, 1.0 / vc.c / vc.z)
                let p2 = ac / vc.nbb
                let gamma = 23.0 * (p2 + 0.305) * t / (23.0 * p1 + 11 * t * hCos + 108.0 * t * hSin)
                let a = gamma * hCos, b = gamma * hSin
                let rA = (460.0 * p2 + 451.0 * a + 288.0 * b) / 1403.0
                let gA = (460.0 * p2 - 891.0 * a - 261.0 * b) / 1403.0
                let bA = (460.0 * p2 - 220.0 * a - 6300.0 * b) / 1403.0
                let linrgb = Math.multiply([inverseChromaticAdaptation(rA), inverseChromaticAdaptation(gA),
                                            inverseChromaticAdaptation(bA)], linrgbFromScaledDiscount)
                if linrgb[0] < 0 || linrgb[1] < 0 || linrgb[2] < 0 { return 0 }
                let fnj = yFromLinrgb[0] * linrgb[0] + yFromLinrgb[1] * linrgb[1] + yFromLinrgb[2] * linrgb[2]
                if fnj <= 0 { return 0 }
                if round == 4 || abs(fnj - y) < 0.002 {
                    if linrgb[0] > 100.01 || linrgb[1] > 100.01 || linrgb[2] > 100.01 { return 0 }
                    return Color.argb(linrgb: linrgb)
                }
                j = j - (fnj - y) * j / (2 * fnj)
            }
            return 0
        }
        static func solveToInt(_ hueDegrees: Double, _ chroma: Double, _ lstar: Double) -> UInt32 {
            if chroma < 0.0001 || lstar < 0.0001 || lstar > 99.9999 { return Color.argb(lstar: lstar) }
            let hueRadians = Math.sanitizeDegrees(hueDegrees) / 180 * Double.pi
            let y = Color.yFromLstar(lstar)
            let exact = findResultByJ(hueRadians, chroma, y)
            if exact != 0 { return exact }
            return Color.argb(linrgb: bisectToLimit(y, hueRadians))
        }
    }
}

/// Every colour FleetView draws with, for one seed, in both appearances (`0xAARRGGBB`).
///
/// `SchemeTonalSpot` at standard contrast: primary at chroma 36 on the seed's hue, secondary 16,
/// tertiary 24 rotated 60°, neutrals 6 and 8, error fixed at hue 25. Two roles are FleetView's own
/// and are built the way M3 builds anything it has no role for:
///   - a running card (`runFresh`/`runSettled`): tone 80 of the primary palette for the first ten
///     seconds in both appearances, then tone 30 (dark) / 40 (light) — see `Theme.runFresh`;
///   - "needs you" (`warn`): #E0A100 harmonised toward the seed, then M3's custom-colour tones
///     (`CorePalette.of(…).a1`, which floors chroma at 48), as `customColor` does — unless that
///     lands it on a status colour; see `warnHue`.
struct MaterialScheme: Equatable {
    enum Role: Int, CaseIterable {
        case primary, onPrimary, primaryContainer, onPrimaryContainer
        case secondaryContainer, onSecondaryContainer
        case tertiary, tertiaryContainer, onTertiaryContainer
        case surface, surfaceContainerLowest, surfaceContainerLow, surfaceContainer,
             surfaceContainerHigh, surfaceContainerHighest
        case onSurface, onSurfaceVariant, outline, outlineVariant, inverseSurface, inverseOnSurface
        case error, errorContainer, onErrorContainer
        case runFresh, onRunFresh, runSettled, onRunSettled
        case warn, warnContainer, onWarnContainer
    }

    /// The default seed: M3's own baseline purple, which the app shipped with before seeds existed.
    static let defaultSeed: UInt32 = 0x6750A4
    /// The swatches offered first — the same five as the website's seed picker.
    static let presets: [(name: String, seed: UInt32)] = [
        ("violet", 0x6750A4), ("blue", 0x1A73E8), ("teal", 0x00897B), ("green", 0x4C8C2B), ("rose", 0xB3261E),
    ]

    let seed: UInt32
    let dark: [UInt32]
    let light: [UInt32]

    init(seed rgb: UInt32) {
        let seed = 0xFF00_0000 | (rgb & 0xFF_FFFF)
        self.seed = rgb & 0xFF_FFFF
        let hct = MaterialColor.Hct(argb: seed)
        typealias P = MaterialColor.TonalPalette
        let p = P(hue: hct.hue, chroma: 36)
        let s = P(hue: hct.hue, chroma: 16)
        let t = P(hue: MaterialColor.Math.sanitizeDegrees(hct.hue + 60), chroma: 24)
        let n = P(hue: hct.hue, chroma: 6)
        let nv = P(hue: hct.hue, chroma: 8)
        let e = P(hue: 25, chroma: 84)
        let amber = MaterialColor.Hct(argb: MaterialColor.harmonize(0xFFE0_A100, toward: seed))
        let w = P(hue: Self.warnHue(amber.hue, running: p.hue, done: t.hue), chroma: max(48, amber.chroma))
        // (palette, tone in dark, tone in light) per role.
        func spec(_ r: Role) -> (P, Double, Double) {
            switch r {
            case .primary:                 return (p, 80, 40)
            case .onPrimary:               return (p, 20, 100)
            case .primaryContainer:        return (p, 30, 90)
            case .onPrimaryContainer:      return (p, 90, 30)
            case .secondaryContainer:      return (s, 30, 90)
            case .onSecondaryContainer:    return (s, 90, 30)
            case .tertiary:                return (t, 80, 40)
            case .tertiaryContainer:       return (t, 30, 90)
            case .onTertiaryContainer:     return (t, 90, 30)
            case .surface:                 return (n, 6, 98)
            case .surfaceContainerLowest:  return (n, 4, 100)
            case .surfaceContainerLow:     return (n, 10, 96)
            case .surfaceContainer:        return (n, 12, 94)
            case .surfaceContainerHigh:    return (n, 17, 92)
            case .surfaceContainerHighest: return (n, 22, 90)
            case .onSurface:               return (n, 90, 10)
            case .onSurfaceVariant:        return (nv, 80, 30)
            case .outline:                 return (nv, 60, 50)
            case .outlineVariant:          return (nv, 30, 80)
            case .inverseSurface:          return (n, 90, 20)
            case .inverseOnSurface:        return (n, 20, 95)
            case .error:                   return (e, 80, 40)
            case .errorContainer:          return (e, 30, 90)
            case .onErrorContainer:        return (e, 90, 30)
            case .runFresh:                return (p, 80, 80)
            case .onRunFresh:              return (p, 20, 20)
            case .runSettled:              return (p, 30, 40)
            case .onRunSettled:            return (p, 90, 100)
            case .warn:                    return (w, 80, 40)
            case .warnContainer:           return (w, 30, 90)
            case .onWarnContainer:         return (w, 90, 10)
            }
        }
        dark = Role.allCases.map { let (pal, d, _) = spec($0); return pal.tone(d) }
        light = Role.allCases.map { let (pal, _, l) = spec($0); return pal.tone(l) }
    }

    func value(_ role: Role, dark isDark: Bool) -> UInt32 { (isDark ? dark : light)[role.rawValue] }

    /// The hue "needs you" is drawn in, given the harmonised amber's hue and the hues of a running
    /// card (primary) and a just-finished one (tertiary).
    ///
    /// Harmonising is M3's rule for a custom colour, but on a third of the wheel it puts the three
    /// card states on top of each other: a yellow seed's running cards are the amber's own hue, and
    /// a red seed's tertiary (60° on) lands on yellow, so "needs you" and "done" were the same brown
    /// side by side in the snapshots. Telling those apart at a glance is the board's whole job, so
    /// the amber keeps its harmonised hue only while it is at least 40° from both; otherwise it
    /// moves, within orange…yellow (45°–110°, still a warning and clear of error's 25°), to the
    /// nearest hue that is — or, when none is (a red seed), to the one farthest from both.
    static func warnHue(_ harmonized: Double, running: Double, done: Double) -> Double {
        let clear = 40.0
        let diff = MaterialColor.Math.differenceDegrees
        func gap(_ h: Double) -> Double { min(diff(h, running), diff(h, done)) }
        if gap(harmonized) >= clear { return harmonized }
        let range = stride(from: 45.0, through: 110.0, by: 1.0)
        if let near = range.filter({ gap($0) >= clear }).min(by: { diff($0, harmonized) < diff($1, harmonized) }) {
            return near
        }
        return range.max(by: { gap($0) < gap($1) }) ?? harmonized
    }

    static func == (a: MaterialScheme, b: MaterialScheme) -> Bool { a.seed == b.seed }
}

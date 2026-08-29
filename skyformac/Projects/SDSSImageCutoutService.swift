import Foundation

/// A real per-object sky image, from SDSS SkyServer's own public "ImgCutout" REST service —
/// unlike the Wikipedia thumbnail (an editorial photo, often not even the same instrument/framing
/// SDSS uses), this is an actual imaging-survey cutout centered on the object's own RA/Dec.
/// Coverage is real but limited to SDSS's own footprint (mostly northern extragalactic sky) — a
/// coordinate outside it still returns a valid (blank/grey) JPEG rather than an error, so this
/// can't reliably distinguish "no coverage here" from "a genuinely dark field"; the caller shows
/// whatever comes back with a caption noting the coverage limit, rather than trying to detect and
/// hide a blank result.
enum SDSSImageCutoutService {
    static func cutoutURL(raDegrees: Double, decDegrees: Double, scaleArcsecPerPixel: Double = 0.4, widthPixels: Int = 400, heightPixels: Int = 400) -> URL? {
        var components = URLComponents(string: "https://skyserver.sdss.org/dr18/SkyServerWS/ImgCutout/getjpeg")
        components?.queryItems = [
            URLQueryItem(name: "ra", value: String(raDegrees)),
            URLQueryItem(name: "dec", value: String(decDegrees)),
            URLQueryItem(name: "scale", value: String(scaleArcsecPerPixel)),
            URLQueryItem(name: "width", value: String(widthPixels)),
            URLQueryItem(name: "height", value: String(heightPixels)),
        ]
        return components?.url
    }
}

using ContextGuard.Feed;

namespace ContextGuard.App;

/// <summary>
/// The tray icon, drawn from the icon font at the taskbar's size, so it is sharp at every scale: the gauge
/// (the Mac's <c>gauge.with.needle</c>), the gauge cut out of a filled circle while a question waits (the
/// Mac fills its gauge), and the gauge switched off. Dark on a light taskbar, white on a dark one.
/// </summary>
static unsafe class TrayIcons
{
    const string Gauge = "\uEC4A", GaugeOff = "\uEC48", Disc = "\uEA3B";
    const uint White = 0xFFFFFF, Black = 0x000000;
    const uint Format = Native.DT_CENTER | Native.DT_VCENTER | Native.DT_SINGLELINE | Native.DT_NOPREFIX | Native.DT_NOCLIP;

    /// <summary>A new icon (the caller destroys it) for a tray state: <c>on</c>, <c>asking</c> or <c>off</c>.</summary>
    public static nint Make(string state, bool lightTaskbar, int size)
    {
        var dc = Native.CreateCompatibleDC(0);
        var header = new Native.BITMAPINFOHEADER
        {
            biSize = (uint)sizeof(Native.BITMAPINFOHEADER),
            biWidth = size,
            biHeight = -size,   // top-down
            biPlanes = 1,
            biBitCount = 32,
        };
        void* bits;
        var color = Native.CreateDIBSection(dc, &header, Native.DIB_RGB_COLORS, &bits, 0, 0);
        var previous = Native.SelectObject(dc, color);
        Native.SetBkMode(dc, (int)Native.TRANSPARENT);

        // The coverage, white on black (a new DIB is all zeros).
        switch (state)
        {
            case "asking":
                Draw(dc, Disc, size, size, White);
                Draw(dc, Gauge, size, (int)Math.Round(size * 0.72), Black);
                break;
            case "off":
                Draw(dc, GaugeOff, size, size, White);
                break;
            default:
                Draw(dc, Gauge, size, size, White);
                break;
        }
        Native.GdiFlush();

        // Coverage becomes alpha, in one color (straight alpha, as in an .ico).
        var rgb = lightTaskbar ? 0x1C1C1Cu : 0xFFFFFFu;
        var pixels = (uint*)bits;
        for (var i = 0; i < size * size; i++)
        {
            var coverage = pixels[i] & 0xFF;
            pixels[i] = coverage << 24 | rgb;
        }

        Native.SelectObject(dc, previous);
        Native.DeleteDC(dc);
        var mask = Native.CreateBitmap(size, size, 1, 1, null);
        var info = new Native.ICONINFO { fIcon = 1, hbmMask = mask, hbmColor = color };
        var icon = Native.CreateIconIndirect(&info);
        Native.DeleteObject(mask);
        Native.DeleteObject(color);
        return icon;
    }

    /// <summary>One glyph, its em box <paramref name="em"/> pixels, centred in the icon.</summary>
    static void Draw(nint dc, string glyph, int size, int em, uint textColor)
    {
        var font = Native.CreateFont(-em, 0, 0, 0, Native.FW_NORMAL, 0, 0, 0, 1, 0, 0, Native.ANTIALIASED_QUALITY, 0, Glyphs.Font);
        var previous = Native.SelectObject(dc, font);
        Native.SetTextColor(dc, textColor);
        var rect = new Native.RECT { Right = size, Bottom = size };
        Native.DrawText(dc, glyph, glyph.Length, &rect, Format);
        Native.SelectObject(dc, previous);
        Native.DeleteObject(font);
    }
}

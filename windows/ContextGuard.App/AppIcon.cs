namespace ContextGuard.App;

/// <summary>
/// The app's icon, drawn as the Mac's app icon (Icons.swift <c>AppIcon</c>): the brand's dark tile with a 1 px
/// edge, rounded 22 %, and the filled gauge in planet violet, its cut-outs in the tile's color. The same in light
/// and dark, like an app icon. Its windows (title bar, taskbar, Alt+Tab) draw it at the size asked for, so it is
/// sharp at every scale; <c>build.ps1</c> puts it in the exe as an .ico (<see cref="WriteIco"/>).
/// </summary>
static unsafe class AppIcon
{
    const double Radius = 0.22, DiscShare = 0.62, GaugeShare = 0.72;
    const int Samples = 4;

    /// <summary>The sizes in the exe's .ico: Windows' small and large icons at 100–250 %, and 256 for Explorer.</summary>
    public static readonly int[] IcoSizes = [16, 20, 24, 32, 40, 48, 64, 256];

    /// <summary>A new icon (the caller destroys it), <paramref name="size"/> pixels square.</summary>
    public static nint Make(int size)
    {
        var header = new Native.BITMAPINFOHEADER
        {
            biSize = (uint)sizeof(Native.BITMAPINFOHEADER),
            biWidth = size,
            biHeight = -size,   // top-down
            biPlanes = 1,
            biBitCount = 32,
        };
        void* bits;
        var color = Native.CreateDIBSection(0, &header, Native.DIB_RGB_COLORS, &bits, 0, 0);
        Pixels(size).CopyTo(new Span<uint>(bits, size * size));
        var mask = Native.CreateBitmap(size, size, 1, 1, null);
        var info = new Native.ICONINFO { fIcon = 1, hbmMask = mask, hbmColor = color };
        var icon = Native.CreateIconIndirect(&info);
        Native.DeleteObject(mask);
        Native.DeleteObject(color);
        return icon;
    }

    /// <summary>
    /// The icon as an .ico file with every size in <see cref="IcoSizes"/>, each a 32-bit bitmap with its alpha
    /// (and an empty mask, which Windows ignores when there's alpha).
    /// </summary>
    public static void WriteIco(string path)
    {
        using var file = new BinaryWriter(File.Create(path));
        file.Write((ushort)0);                      // reserved
        file.Write((ushort)1);                      // an icon
        file.Write((ushort)IcoSizes.Length);
        var offset = 6 + 16 * IcoSizes.Length;
        var images = new List<byte[]>();
        foreach (var size in IcoSizes)
        {
            var image = IcoImage(size);
            images.Add(image);
            file.Write((byte)(size >= 256 ? 0 : size));   // 0 means 256
            file.Write((byte)(size >= 256 ? 0 : size));
            file.Write((byte)0);                    // no palette
            file.Write((byte)0);
            file.Write((ushort)1);                  // planes
            file.Write((ushort)32);                 // bits per pixel
            file.Write(image.Length);
            file.Write(offset);
            offset += image.Length;
        }
        foreach (var image in images) file.Write(image);
    }

    /// <summary>One .ico image: a bitmap header (twice the height: the colors, then the mask), bottom-up rows.</summary>
    static byte[] IcoImage(int size)
    {
        var maskRow = (size + 31) / 32 * 4;
        using var stream = new MemoryStream();
        using var image = new BinaryWriter(stream);
        image.Write(40);                            // BITMAPINFOHEADER
        image.Write(size);
        image.Write(size * 2);
        image.Write((ushort)1);
        image.Write((ushort)32);
        image.Write(0);                             // BI_RGB
        image.Write(size * size * 4 + maskRow * size);
        image.Write(0);
        image.Write(0);
        image.Write(0);
        image.Write(0);
        var pixels = Pixels(size);
        for (var y = size - 1; y >= 0; y--)
            for (var x = 0; x < size; x++) image.Write(pixels[y * size + x]);
        image.Write(new byte[maskRow * size]);
        image.Flush();
        return stream.ToArray();
    }

    /// <summary>The icon's pixels, top-down, each 0xAARRGGBB with straight alpha.</summary>
    static uint[] Pixels(int size)
    {
        var em = (int)Math.Round(size * DiscShare);
        var disc = Coverage(TrayIcons.Disc, size, em);
        var gauge = Coverage(TrayIcons.Gauge, size, (int)Math.Round(em * GaugeShare));
        var (tileR, tileG, tileB) = Rgb(BrandColors.IconTile.Dark);
        var (edgeR, edgeG, edgeB) = Rgb(BrandColors.IconEdge.Dark);
        var (planetR, planetG, planetB) = Rgb(BrandColors.Planet.Dark);
        var radius = size * Radius;
        var pixels = new uint[size * size];
        for (var y = 0; y < size; y++)
        {
            for (var x = 0; x < size; x++)
            {
                var i = y * size + x;
                // Premultiplied while composing: the tile, its edge over it, the disc, the gauge cut out of the disc.
                var tile = RoundedRect(x, y, 0, size, radius);
                var ring = tile - RoundedRect(x, y, 1, size - 2, Math.Max(0, radius - 1));
                double a = tile, r = tileR * tile, g = tileG * tile, b = tileB * tile;
                r += (edgeR - tileR) * ring; g += (edgeG - tileG) * ring; b += (edgeB - tileB) * ring;
                var d = disc[i] / 255.0;
                r = r * (1 - d) + planetR * d; g = g * (1 - d) + planetG * d; b = b * (1 - d) + planetB * d; a = a * (1 - d) + d;
                var cut = gauge[i] / 255.0;
                r = r * (1 - cut) + tileR * a * cut; g = g * (1 - cut) + tileG * a * cut; b = b * (1 - cut) + tileB * a * cut;
                // An icon's pixels are straight alpha.
                pixels[i] = a <= 0 ? 0 : (uint)Math.Round(a * 255) << 24
                    | (uint)Math.Round(r / a) << 16 | (uint)Math.Round(g / a) << 8 | (uint)Math.Round(b / a);
            }
        }
        return pixels;
    }

    /// <summary>How much of each pixel a glyph covers (0–255), centred, its em box <paramref name="em"/> pixels.</summary>
    static byte[] Coverage(string glyph, int size, int em)
    {
        var dc = Native.CreateCompatibleDC(0);
        var header = new Native.BITMAPINFOHEADER
        {
            biSize = (uint)sizeof(Native.BITMAPINFOHEADER),
            biWidth = size,
            biHeight = -size,
            biPlanes = 1,
            biBitCount = 32,
        };
        void* bits;
        var bitmap = Native.CreateDIBSection(dc, &header, Native.DIB_RGB_COLORS, &bits, 0, 0);
        var previous = Native.SelectObject(dc, bitmap);
        Native.SetBkMode(dc, (int)Native.TRANSPARENT);
        TrayIcons.Draw(dc, glyph, size, em, 0xFFFFFF);   // white on the new DIB's black
        Native.GdiFlush();
        var coverage = new byte[size * size];
        var pixels = (uint*)bits;
        for (var i = 0; i < coverage.Length; i++) coverage[i] = (byte)(pixels[i] & 0xFF);
        Native.SelectObject(dc, previous);
        Native.DeleteObject(bitmap);
        Native.DeleteDC(dc);
        return coverage;
    }

    /// <summary>How much of pixel (x, y) a rounded square covers: <paramref name="side"/> pixels from <paramref name="at"/>.</summary>
    static double RoundedRect(int x, int y, double at, double side, double radius)
    {
        var inside = 0;
        for (var sy = 0; sy < Samples; sy++)
        {
            for (var sx = 0; sx < Samples; sx++)
            {
                var px = x + (sx + 0.5) / Samples - at;
                var py = y + (sy + 0.5) / Samples - at;
                if (px < 0 || py < 0 || px > side || py > side) continue;
                // Distance into the nearest corner's square; outside the corner's circle is outside.
                var cx = Math.Max(radius - px, px - (side - radius));
                var cy = Math.Max(radius - py, py - (side - radius));
                if (cx > 0 && cy > 0 && cx * cx + cy * cy > radius * radius) continue;
                inside++;
            }
        }
        return inside / (double)(Samples * Samples);
    }

    static (double R, double G, double B) Rgb(uint rgb) => ((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);
}

# paperless-naps2-deskew

Dockerized NAPS2 deskew watcher for Paperless-ngx.

This container watches an input directory for PDF files, runs the NAPS2 Linux CLI with deskew enabled, and writes the processed PDFs to an output directory. It is designed to run next to Paperless-ngx in the same Docker Compose stack: scanners write to a staging folder, this container preprocesses the scanned PDFs, and Paperless imports only the NAPS2-processed files.

## Why NAPS2 instead of OCRmyPDF?

This project intentionally does **not** use OCRmyPDF for deskewing. Paperless-ngx already uses OCRmyPDF internally during document import. The purpose of this container is to use NAPS2 deskewing as a preprocessing step before Paperless imports the file, while leaving OCR and final document handling to Paperless. Because PDFs are rasterized before NAPS2 processing, this is intended for scanned/image PDFs rather than born-digital text PDFs.

Recommended Paperless settings for this flow:

```yaml
services:
  webserver:
    volumes:
      - /path/to/paperless-ngx/consume:/usr/src/paperless/consume
    environment:
      PAPERLESS_OCR_DESKEW: "false"
      PAPERLESS_OCR_CLEAN: "none"
      PAPERLESS_CONSUMER_POLLING: 10
```

## How the flow works

1. Your scanner writes PDFs to `/path/to/paperless-ngx/scans`.
2. `paperless-naps2-deskew` watches that folder as `/input`.
3. For each stable top-level PDF, the container copies it to a temporary work directory and detects the embedded scan DPI with Poppler `pdfimages -list`.
4. It rasterizes pages to PNG images with Poppler `pdftoppm` at the selected source-aware DPI, then runs NAPS2 deskewing on those images.
5. The NAPS2 PDF is optionally post-processed with Ghostscript to downsample and JPEG-compress scan images without using OCRmyPDF.
6. The deskewed image-based PDF is written atomically to `/path/to/paperless-ngx/consume` as `/output`.
7. Paperless-ngx consumes files from `/path/to/paperless-ngx/consume` and performs OCR afterward.
8. On success, the original input is moved to `/input/.processed` when `ARCHIVE_ORIGINALS=true`; otherwise it is deleted.
9. On failure, the original input is moved to `/input/.failed`.

Paperless should **not** watch the scanner staging folder directly. If Paperless imports files before this container preprocesses them, the Paperless consume mount is pointed at the wrong directory.

## Docker Compose example

```yaml
services:
  paperless-naps2-deskew:
    image: nillivanilli0815/paperless-naps2-deskew:latest
    container_name: paperless-naps2-deskew
    restart: unless-stopped
    environment:
      PUID: 1000
      PGID: 1000
      INPUT_DIR: /input
      OUTPUT_DIR: /output
      POLL_SECONDS: 10
      PDF_RENDER_DPI: auto
      PDF_RENDER_DPI_FALLBACK: 200
      PDF_RENDER_DPI_MIN: 150
      PDF_RENDER_DPI_MAX: 300
      POSTPROCESS_GHOSTSCRIPT: "true"
      GS_DOWNSAMPLE_DPI: auto
      GS_DOWNSAMPLE_DPI_FALLBACK: 200
      GS_JPEG_QUALITY: 90
      GS_COMPATIBILITY_LEVEL: "1.7"
      ARCHIVE_ORIGINALS: "true"
      NAPS2_EXTRA_ARGS: ""
    volumes:
      - /path/to/paperless-ngx/scans:/input
      - /path/to/paperless-ngx/consume:/output
      # Optional: persist NAPS2/.NET config and cache data
      # - /path/to/paperless-ngx/naps2-config:/naps2
```

A standalone copy of this service is available in [`compose.example.yml`](compose.example.yml).

## Environment variables

| Variable | Default | Description |
| --- | --- | --- |
| `INPUT_DIR` | `/input` | Directory watched for top-level PDF files. |
| `OUTPUT_DIR` | `/output` | Directory where processed PDFs are written. |
| `POLL_SECONDS` | `10` | Poll interval and file-stability check interval. |
| `PDF_RENDER_DPI` | `auto` | DPI used when rasterizing PDF pages to PNG images before NAPS2 deskewing. `auto` is recommended: the watcher detects embedded scan DPI with `pdfimages -list` and preserves that DPI instead of blindly rendering everything at 300 dpi. You may also set a numeric DPI such as `200`, `250`, or `300`. |
| `PDF_RENDER_DPI_FALLBACK` | `200` | Render DPI used when `PDF_RENDER_DPI=auto` and no valid embedded image DPI can be detected. |
| `PDF_RENDER_DPI_MIN` | `150` | Lower clamp for detected or numeric render DPI values. |
| `PDF_RENDER_DPI_MAX` | `300` | Upper clamp for detected or numeric render DPI values. |
| `POSTPROCESS_GHOSTSCRIPT` | `true` | Run Ghostscript after NAPS2 to recompress/downsample the image-based PDF. If Ghostscript fails or produces an empty file, the watcher logs a warning and falls back to the uncompressed NAPS2 PDF. |
| `GS_DOWNSAMPLE_DPI` | `auto` | Ghostscript color/gray image downsample DPI. `auto` uses the selected render/source DPI; a numeric value overrides it. Values are clamped with the same min/max DPI settings. |
| `GS_DOWNSAMPLE_DPI_FALLBACK` | `200` | Ghostscript downsample DPI used if `GS_DOWNSAMPLE_DPI=auto` and no valid render DPI is available. |
| `GS_JPEG_QUALITY` | `90` | JPEG quality passed to Ghostscript (`-dJPEGQ`). `90` is a good default for scan quality and file size. Lower values reduce file size but may create artifacts; higher values can improve visual quality but create larger files. |
| `GS_COMPATIBILITY_LEVEL` | `1.7` | PDF compatibility level passed to Ghostscript. |
| `ARCHIVE_ORIGINALS` | `true` | Move successful inputs to `/input/.processed` when true; delete them when false. |
| `NAPS2_EXTRA_ARGS` | empty | Additional arguments appended to the NAPS2 command before `-o`. Simple whitespace-separated values are supported. |
| `PUID` | `1000` | Runtime user id for the non-root watcher process. |
| `PGID` | `1000` | Runtime group id for the non-root watcher process. |

## DPI and output-size strategy

The default pipeline is source-aware. Many scanner PDFs are already around 200 dpi and contain one efficiently compressed JPEG per page. Rendering those files at a fixed 300 dpi upscales the scan without adding real detail, increases the number of pixels NAPS2 has to process, and can make the final PDF much larger.

With `PDF_RENDER_DPI=auto`, the watcher runs `pdfimages -list` before rasterizing, ignores invalid or empty DPI values, chooses a sensible detected image DPI, and clamps it between `PDF_RENDER_DPI_MIN` and `PDF_RENDER_DPI_MAX`. If no valid DPI is found, it uses `PDF_RENDER_DPI_FALLBACK` (200 dpi by default). For normal scanned documents, 200 dpi is usually enough and should usually remain around 200 dpi. Using 250 or 300 dpi may look slightly better for some scans, but it increases file size and processing time.

After NAPS2 deskews the PNG imports, `POSTPROCESS_GHOSTSCRIPT=true` recompresses the temporary NAPS2 PDF. By default `GS_DOWNSAMPLE_DPI=auto` uses the same selected source/render DPI, and `GS_JPEG_QUALITY=90` keeps visual quality close to the original or Paperless-only output while reducing the oversized RGB image PDFs that NAPS2 can otherwise create. Lowering JPEG quality reduces file size but can introduce artifacts; increasing JPEG quality improves visual quality but creates larger files.

## NAPS2 home and optional persistent config

NAPS2 and the .NET runtime need a writable application/config home. The image creates `/naps2` and the entrypoint sets:

- `HOME=/naps2`
- `XDG_CONFIG_HOME=/naps2/.config`
- `XDG_DATA_HOME=/naps2/.local/share`
- `XDG_CACHE_HOME=/naps2/.cache`
- `DOTNET_CLI_HOME=/naps2/.dotnet`

On startup, the container creates these directories and chowns `/naps2` to the configured `PUID`/`PGID` before dropping privileges. You normally do not need to mount this path, but you may optionally persist it if you want NAPS2/.NET config and cache data to survive container recreation:

```yaml
volumes:
  - /path/to/paperless-ngx/naps2-config:/naps2
```

## NAPS2 command

On Debian/Ubuntu package installs, the [official NAPS2 command-line documentation](https://www.naps2.com/doc/command-line) documents the Linux CLI alias as:

```bash
naps2 console
```

This container first rasterizes each PDF page to PNG with `pdftoppm` and then imports the generated page images into NAPS2. It uses this NAPS2 command shape for each rendered image set:

```bash
naps2 console -i "page-1.png;page-2.png" -n 0 --deskew --disableocr ${NAPS2_EXTRA_ARGS} -o output.pdf -f
```

The important options are:

- `pdfimages -list input.pdf` detects embedded scan DPI when `PDF_RENDER_DPI=auto`.
- `pdftoppm -r "$selected_render_dpi" -png input.pdf page` renders the PDF pages to PNG images first.
- `-i` imports a semicolon-separated list of the rendered PNG page images.
- `-n 0` prevents scanning and processes only imported pages.
- `--deskew` enables automatic deskewing.
- `--disableocr` disables NAPS2 OCR so Paperless-ngx can perform OCR later.
- `-o` exports the result as a PDF.
- `-f` allows NAPS2 to overwrite the temporary per-job output file if needed.

The official NAPS2 command-line documentation lists `--deskew` under post-processing options and `--disableocr` under OCR options. If a future NAPS2 release changes these options, check `naps2 console --help` inside the image and override behavior with `NAPS2_EXTRA_ARGS` only when compatible.

## File handling details

- Only PDF files in the top level of `/input` are processed.
- `/input/.processed`, `/input/.failed`, hidden directories, and nested files are ignored.
- Hidden files and common partial/temp suffixes such as `.part`, `.partial`, `.tmp`, `.temp`, `.crdownload`, and backup `~` files are skipped.
- A file is processed only after its size and modification timestamp remain unchanged across a polling interval.
- PDF pages are rendered to PNG images at the selected source-aware render DPI before NAPS2 imports them for deskewing.
- When `POSTPROCESS_GHOSTSCRIPT=true`, the NAPS2 PDF is recompressed with Ghostscript before final output.
- Output is first written to a temporary file and then atomically moved into place.
- Existing output files are never overwritten. If the original filename already exists, a UTC timestamp and, if necessary, a numeric suffix are appended.
- Logs are one-line messages suitable for `docker logs`.

## Local test

Build the image locally:

```bash
docker build -t paperless-naps2-deskew:local .
```

Run it with two mounted folders:

```bash
mkdir -p /tmp/naps2-deskew-test/input /tmp/naps2-deskew-test/output

docker run --rm \
  -e PUID="$(id -u)" \
  -e PGID="$(id -g)" \
  -e POLL_SECONDS=2 \
  -e PDF_RENDER_DPI=auto \
  -e POSTPROCESS_GHOSTSCRIPT=true \
  -v /tmp/naps2-deskew-test/input:/input \
  -v /tmp/naps2-deskew-test/output:/output \
  paperless-naps2-deskew:local
```

Drop a sample scanned PDF into `/tmp/naps2-deskew-test/input`, then verify that a processed PDF appears in `/tmp/naps2-deskew-test/output`. If `ARCHIVE_ORIGINALS=true`, the original should move to `/tmp/naps2-deskew-test/input/.processed`.

## NAPS2 Linux package source

The Docker image installs NAPS2 from the [official NAPS2 Apt repository](https://www.naps2.com/linux-scanning), using the project public key and the `https://downloads.naps2.com ./` Apt source.

## GitHub Actions and Docker Hub publishing

The workflow in `.github/workflows/docker.yml` uses Docker Buildx, GitHub Actions cache, and Docker metadata action.

It will:

- Build pull requests without pushing an image.
- Build pushes to `main` and push `latest` plus a SHA tag.
- Build tags like `v1.2.3` and push semver tags such as `1.2.3`, `1.2`, `1`, plus a SHA tag.
- Rebuild once per month on a schedule, pushing `latest`, a `monthly-YYYY-MM` tag, and a SHA tag to refresh the Docker image with current base image and Apt package versions.
- Allow manual rebuilds from GitHub Actions, with an optional `no_cache` input for cache-free rebuilds on the default branch.
- Push to `nillivanilli0815/paperless-naps2-deskew`.
- Build `linux/amd64` by default.

Scheduled monthly rebuilds intentionally set `pull: true` and `no-cache: true` so Docker pulls the current base image and does not reuse stale Docker layers for Apt package installation. Normal push, tag, pull request, and default manual builds still use GitHub Actions build cache (`cache-from: type=gha` and `cache-to: type=gha,mode=max`) for faster builds.

Setup steps:

1. Create the Docker Hub repository `paperless-naps2-deskew` under the Docker Hub user `nillivanilli0815`.
2. Create a Docker Hub access token.
3. In the GitHub repository `nilleiz/paperless-naps2-deskew`, add the repository secret `DOCKERHUB_TOKEN` with that token value.

`linux/arm64` is intentionally not enabled by default. Add it to the workflow platforms only after verifying that the official NAPS2 Linux package supports arm64 reliably for the release you want to publish.

## Updating

Pull the latest image and recreate the container:

```bash
docker compose pull paperless-naps2-deskew
docker compose up -d --force-recreate paperless-naps2-deskew
```

## Troubleshooting

### Check logs

Use Docker logs first:

```bash
docker logs paperless-naps2-deskew
```

The watcher logs startup, detected files, file-stability waits, processing starts, successes, failures, and skipped files as one-line messages.

### File permissions / UID and GID

If the container cannot read `/input` or write `/output`, set `PUID` and `PGID` to a user/group that owns the mounted folders:

```yaml
environment:
  PUID: 1000
  PGID: 1000
```

Also verify host permissions on both mounted directories. If you mount a persistent NAPS2 config directory to `/naps2`, make sure the configured `PUID`/`PGID` can write to it as well.

### NAPS2 cannot import PNG pages / GdkPixbuf missing

If logs show `System.DllNotFoundException: GdkPixbuf`, `libgdk_pixbuf-2.0.so.0`, or `Error importing image: .../pages/page-1.png`, the image is missing GTK/GdkPixbuf runtime libraries required by NAPS2 to load the rendered PNG pages. Pull a newer image and recreate the container:

```bash
docker compose pull paperless-naps2-deskew
docker compose up -d --force-recreate paperless-naps2-deskew
```

You can verify a fixed image by checking that GdkPixbuf resolves inside the container:

```bash
ldconfig -p | grep libgdk_pixbuf-2.0.so.0
```

### Failed files

Files that fail NAPS2 processing are moved to:

```text
/input/.failed
```

Inspect `docker logs` for the matching `processing failure` line, then test the file manually if needed.

### Processed originals

When `ARCHIVE_ORIGINALS=true`, successful original PDFs are moved to:

```text
/input/.processed
```

Set `ARCHIVE_ORIGINALS=false` if you want originals deleted after successful preprocessing.

### Paperless imports before preprocessing

Paperless must consume from the deskew output folder, not the scanner input folder. For the example layout:

- scanner staging: `/path/to/paperless-ngx/scans`
- deskew output / Paperless consume: `/path/to/paperless-ngx/consume`

If Paperless imports files before NAPS2 processes them, the Paperless consume volume is probably mounted to `/path/to/paperless-ngx/scans` by mistake.

### Existing text layers and scanned-PDF assumptions

The container rasterizes each PDF page and asks NAPS2 to export a new image-based PDF while applying deskew. Existing PDFs with text layers will lose or change those text layers, so this container is mainly intended for scanned/image-only PDFs that will be OCRed by Paperless-ngx afterward.

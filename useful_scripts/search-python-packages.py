                      help="maximum name matches to inspect (default: 80)")
  parser.add_argument("--threads", type=positive, default=4,
                      help="parallel metadata fetches (default: 4)")
  parser.add_argument("--with-conda", action="store_true",
                      help="show exact name matches in conda-forge")
  parser.add_argument("--csv", metavar="FILE", help="save results as CSV")
  parser.add_argument("--pdf", metavar="FILE",
                      help="save a multipage PDF (requires reportlab)")
  parser.add_argument("--install", action="store_true",
                      help="prompt to install selected packages with pip")
  args = parser.parse_intermixed_args()
  if args.threads > 16 or args.candidates > 500:
    parser.error("--threads must be <= 16 and --candidates <= 500")
  if not any(part.strip() for part in args.query):
    parser.error("supply at least one nonempty keyword")

  query = " ".join(args.query)
  try:
    with CONSOLE.status("Loading PyPI project names..."):
      names = fetch_pypi_index()
  except (requests.RequestException, ValueError, KeyError) as error:
    CONSOLE.print(f"[red]Could not load PyPI index:[/red] {error}")
    return 1

  candidates, total, fuzzy = find_candidates(
    args.query, names, args.match, args.candidates
  )
  if not candidates:
    CONSOLE.print("[yellow]No matching project names. Try --match any "
                  "or different keywords.[/yellow]")
    return 1
  if fuzzy:
    CONSOLE.print("[yellow]No exact name match; showing fuzzy "
                  "suggestions.[/yellow]")
  CONSOLE.print(f"Inspecting {len(candidates)} of {total:,} matched "
                "project names (ranked by name relevance).")

  with CONSOLE.status("Fetching project dates and recent downloads..."):
    with ThreadPoolExecutor(max_workers=args.threads) as pool:
      fetched = list(pool.map(lambda pair: package_info(pair, args.period),
                              candidates))
  rows = [pkg for pkg in fetched if pkg is not None]
  if not rows:
    CONSOLE.print("[red]No project metadata could be retrieved.[/red]")
    return 1
  if len(rows) < len(candidates):
    CONSOLE.print(f"[yellow]Metadata unavailable for "
                  f"{len(candidates) - len(rows)} projects.[/yellow]")
  missing = sum(pkg.downloads is None for pkg in rows)
  if missing:
    CONSOLE.print(f"[yellow]Downloads unavailable for {missing} "
                  "projects; shown as — and sorted last.[/yellow]")

  if args.since:
    rows = [pkg for pkg in rows if
            (getattr(pkg, args.date_field) is not None and
             getattr(pkg, args.date_field).date() >= args.since)]
  rows = sort_packages(rows, args.sort)[:args.limit]
  if not rows:
    CONSOLE.print("[yellow]No inspected projects meet the date filter.[/]")
    return 1

  if args.with_conda:
    with CONSOLE.status("Loading conda-forge names..."):
      conda_names = load_conda_names()
    if not conda_names:
      CONSOLE.print("[yellow]Could not load conda-forge names.[/yellow]")
    rows = [replace(pkg, conda=conda_names.get(canonical(pkg.name), ""))
            for pkg in rows]

  table = Table(title=Text(f"PyPI: {query} | sort: {args.sort}"))
  table.add_column("#", justify="right")
  table.add_column("Package")
  if args.with_conda:
    table.add_column("conda-forge", style="cyan")
  table.add_column("First upload UTC")
  table.add_column("Last upload UTC")
  table.add_column(f"DL / last {args.period}", justify="right")
  table.add_column("Summary")
  for index, pkg in enumerate(rows, 1):
    cells = [str(index), Text(pkg.name, style="bold")]
    if args.with_conda:
      cells.append(pkg.conda or "—")
    cells += [date_text(pkg.created), date_text(pkg.updated),
              count_text(pkg.downloads), Text(pkg.summary)]
    table.add_row(*cells)
  CONSOLE.print(table)

  try:
    if args.csv:
      write_csv(args.csv, rows, args.period)
      CONSOLE.print(f"CSV saved: {args.csv}")
    if args.pdf:
      write_pdf(args.pdf, query, args.sort, args.period, rows,
                args.with_conda)
      CONSOLE.print(f"PDF saved: {args.pdf}")
  except (OSError, RuntimeError) as error:
    CONSOLE.print(f"[red]Export failed:[/red] {error}")
    return 1

  if args.install:
    try:
      chosen = parse_selection(
        input("Package numbers to install (e.g. 1, 3-5): "), len(rows)
      )
      if chosen:
        packages = [rows[index - 1].name for index in chosen]
        subprocess.run([sys.executable, "-m", "pip", "install", *packages],
                       check=True)
      else:
        CONSOLE.print("No packages selected.")
    except (ValueError, EOFError, KeyboardInterrupt,
            subprocess.CalledProcessError) as error:
      CONSOLE.print(f"[red]Installation aborted:[/red] {error}")
      return 1
  return 0


if __name__ == "__main__":
  sys.exit(main())


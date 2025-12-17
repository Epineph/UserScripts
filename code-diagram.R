#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(igraph)
  library(ggraph)
  library(ggplot2)
  library(grid)
})

# ------------------------------------------------------------
# make_place_response_circularity_plot.R
#
# Purpose:
#   Create a Python-independent diagram illustrating how a
#   forced-choice "place vs response" probe can become circular:
#   observed bin -> labelled strategy, while unmeasured factors
#   can drive the same bins (non-identifiability).
#
# Dependencies:
#   igraph, ggraph, ggplot2
#
# Usage:
#   ./make_place_response_circularity_plot.R --out plot.png
# ------------------------------------------------------------

function parse_args() {
  args <- commandArgs(trailingOnly = TRUE)
  out <- "place_response_circularity_R.png"

  if (length(args) == 0) {
    return(list(out = out))
  }

  if (any(args %in% c("-h", "--help"))) {
    cat(
      "Usage:\n",
      "  make_place_response_circularity_plot.R [--out FILE]\n\n",
      "Options:\n",
      "  --out FILE   Output PNG path (default: place_response_circularity_R.png)\n",
      "  -h, --help   Show this help\n",
      sep = ""
    )
    quit(status = 0)
  }

  for (i in seq_along(args)) {
    if (args[i] == "--out" && i < length(args)) {
      out <- args[i + 1]
    }
  }

  list(out = out)
}

function stop_if_missing_packages(pkgs) {
  missing <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]
  if (length(missing) > 0) {
    stop(
      "Missing R packages: ", paste(missing, collapse = ", "), "\n",
      "Install, e.g.: install.packages(c(",
      paste(sprintf("%s", shQuote(missing)), collapse = ", "),
      "))\n",
      call. = FALSE
    )
  }
}

function make_plot(out) {
  stop_if_missing_packages(c("igraph", "ggraph", "ggplot2", "grid"))

  # ---------------------------
  # Nodes: manual layout
  # ---------------------------
  nodes <- data.frame(
    name = c("prem", "probe", "obsP", "obsR", "conP", "conR", "circ",
             "alt", "altP", "altR"),
    label = c(
      "Hidden premises\n(rarely stated)\n\n1) Place XOR Response\n(exhaustive + exclusive)\n2) Probe choice ≈ Strategy\n(classification rule)",
      "Forced-choice probe\n(start position changed)\n\nOnly two bins:\nPlace-arm OR Response-arm",
      "Observed:\nchooses PLACE arm",
      "Observed:\nchooses RESPONSE arm",
      "Conclusion:\n'Place strategy'\n(P)",
      "Conclusion:\n'Response strategy'\n(R)",
      "Circularity:\nAll outcomes\n'confirm' the model\nbecause labels are\nread off the bins",
      "Unmeasured contributors\n(can drive the same choice)\n\n• expression/selection/inhibition\n• motor/program selection limits\n• cue affordances / environment\n• probe novelty / conflict",
      "Alt. explanation for\nPLACE-arm choice:\n\n'Not response' (impairment)\n≠ 'Uses place'",
      "Alt. explanation for\nRESPONSE-arm choice:\n\n'Not place' (impairment)\n≠ 'Uses response'"
    ),
    x = c(0, 0, -4, 4, -4, 4, 0, 0, -4, 4),
    y = c(9, 7.5, 6, 6, 3.5, 3.5, 1.5, 5, 4.8, 4.8),
    shape = c("ellipse", "box", "circle", "circle", "circle", "circle",
              "circle", "box", "box", "box"),
    fill = c("#b7d7e8", "#dfeaf3", "#b6f2b6", "#b6f2b6", "#f28c8c",
             "#f28c8c", "#ff6b6b", "#e6e6e6", "#fff3bf", "#fff3bf"),
    stringsAsFactors = FALSE
  )

  # ---------------------------
  # Edges
  # ---------------------------
  edges <- data.frame(
    from = c("prem","probe","probe","obsP","obsR","conP","conR",
             "alt","alt",
             "obsP","obsR",
             "altP","altR"),
    to   = c("probe","obsP","obsR","conP","conR","circ","circ",
             "obsP","obsR",
             "altP","altR",
             "conP","conR"),
    style = c("solid","solid","solid","solid","solid","solid","solid",
              "dashed","dashed",
              "dashed","dashed",
              "dashed","dashed"),
    elabel = c("", "", "", "", "", "", "",
               "", "",
               "", "",
               "(invalid inference\nif assumed)",
               "(invalid inference\nif assumed)"),
    stringsAsFactors = FALSE
  )

  # igraph object
  g <- graph_from_data_frame(edges[, c("from", "to")], directed = TRUE,
                             vertices = nodes)

  # Attach edge aesthetics
  E(g)$style <- edges$style
  E(g)$elabel <- edges$elabel

  # Manual layout matrix: must match V(g)$name order
  layout_df <- data.frame(
    name = V(g)$name,
    x = nodes$x[match(V(g)$name, nodes$name)],
    y = nodes$y[match(V(g)$name, nodes$name)]
  )
  lay <- as.matrix(layout_df[, c("x", "y")])

  # Node aesthetics aligned to igraph vertex order
  V(g)$label <- nodes$label[match(V(g)$name, nodes$name)]
  V(g)$fill  <- nodes$fill[match(V(g)$name, nodes$name)]
  V(g)$shape <- nodes$shape[match(V(g)$name, nodes$name)]

  # ---------------------------
  # Plot
  # ---------------------------
  p <- ggraph(g, layout = "manual", x = lay[, 1], y = lay[, 2]) +
    geom_edge_link(
      aes(linetype = style),
      arrow = arrow(length = unit(3.0, "mm"), type = "closed"),
      end_cap = circle(7, "mm"),
      start_cap = circle(7, "mm"),
      edge_width = 0.6,
      edge_alpha = 0.95
    ) +
    geom_edge_label(
      aes(label = ifelse(elabel == "", NA, elabel)),
      label.size = NA,
      fill = "white",
      label.r = unit(0.15, "lines"),
      size = 3,
      repel = TRUE
    ) +
    geom_node_label(
      aes(label = label, fill = fill),
      label.size = 0.4,
      color = "black",
      size = 3.4,
      lineheight = 0.95,
      label.r = unit(0.25, "lines"),
      show.legend = FALSE
    ) +
    scale_fill_identity() +
    scale_linetype_manual(values = c(solid = "solid", dashed = "dashed")) +
    theme_void(base_size = 12) +
    ggtitle("Why a direct-opposition probe can become circular") +
    theme(
      plot.title = element_text(hjust = 0.5, face = "bold"),
      plot.margin = margin(10, 10, 10, 10)
    )

  ggsave(out, p, width = 8.5, height = 10, dpi = 220)
  cat("Wrote:", out, "\n")
}

args <- parse_args()
make_plot(args$out)

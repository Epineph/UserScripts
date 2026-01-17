# app.R
# Interactive Bayes (diagnostic testing) — single & sequential tests
# Dependencies: shiny, ggplot2
# Run: shiny::runApp("path/to/app.R")

suppressPackageStartupMessages({
  library(shiny)
  library(ggplot2)
})

# ---------- Utilities ---------------------------------------------------------

clamp01 <- function(x) pmin(pmax(x, 0), 1)
fmt_pct <- function(x, digits = 2) sprintf(paste0("%.", digits, "f%%"), 100 * x)
fmt_num <- function(x) format(round(x, 0), big.mark = ",")

# PPV / NPV given prior p, sensitivity Se, specificity Sp
ppv <- function(p, Se, Sp) {
  Se <- clamp01(Se); Sp <- clamp01(Sp); p <- clamp01(p)
  num <- Se * p
  den <- Se * p + (1 - Sp) * (1 - p)
  if (den == 0) return(NA_real_)
  num / den
}
npv <- function(p, Se, Sp) {
  Se <- clamp01(Se); Sp <- clamp01(Sp); p <- clamp01(p)
  num <- Sp * (1 - p)
  den <- (1 - Se) * p + Sp * (1 - p)
  if (den == 0) return(NA_real_)
  num / den
}

# Likelihood ratios
lr_pos <- function(Se, Sp) {
  Se <- clamp01(Se); Sp <- clamp01(Sp)
  den <- (1 - Sp)
  if (den == 0) return(Inf)
  Se / den
}
lr_neg <- function(Se, Sp) {
  Se <- clamp01(Se); Sp <- clamp01(Sp)
  den <- Sp
  if (den == 0) return(Inf)
  (1 - Se) / den
}

# Posterior from prior via LR
posterior_from_lr <- function(p_prior, LR) {
  p_prior <- clamp01(p_prior)
  if (p_prior %in% c(0, 1)) return(p_prior)
  odds <- p_prior / (1 - p_prior)
  post_odds <- odds * LR
  post_odds / (1 + post_odds)
}

# One test update (outcome = "Positive" | "Negative")
update_once <- function(p_prior, Se, Sp, outcome) {
  if (identical(outcome, "Positive")) {
    LR <- lr_pos(Se, Sp)
  } else {
    LR <- lr_neg(Se, Sp)
  }
  p_post <- posterior_from_lr(p_prior, LR)
  list(
    prior = p_prior,
    Se = Se, Sp = Sp, outcome = outcome,
    LR = LR, posterior = p_post
  )
}

# Sequential updates for a list of tests (each: list(Se, Sp, outcome))
update_sequence <- function(p0, tests) {
  steps <- list()
  p <- p0
  for (i in seq_along(tests)) {
    t <- tests[[i]]
    st <- update_once(p, t$Se, t$Sp, t$outcome)
    steps[[i]] <- st
    p <- st$posterior
  }
  # Row-bind
  if (length(steps) == 0) return(data.frame())
  do.call(rbind, lapply(seq_along(steps), function(i) {
    data.frame(
      step = i,
      prior = steps[[i]]$prior,
      Se = steps[[i]]$Se,
      Sp = steps[[i]]$Sp,
      outcome = steps[[i]]$outcome,
      LR = steps[[i]]$LR,
      posterior = steps[[i]]$posterior
    )
  }))
}

# Confusion matrix for an example cohort size N
confusion_matrix <- function(p, Se, Sp, N = 10000) {
  p <- clamp01(p); Se <- clamp01(Se); Sp <- clamp01(Sp)
  D  <- N * p
  ND <- N - D
  TP <- D * Se
  FN <- D * (1 - Se)
  TN <- ND * Sp
  FP <- ND * (1 - Sp)
  data.frame(
    "", "Disease +" = c(fmt_num(TP), fmt_num(FN), fmt_num(D)),
    "Disease -" = c(fmt_num(FP), fmt_num(TN), fmt_num(ND)),
    "Total"     = c(fmt_num(TP + FP), fmt_num(FN + TN), fmt_num(N))
  , check.names = FALSE, row.names = c("Test +", "Test -", "Total"))
}

# ---------- UI ----------------------------------------------------------------

ui <- fluidPage(
  tags$head(
    tags$title("Interactive Bayes (Diagnostics)"),
    tags$style(HTML("
      .small-note { color:#555; font-size:0.92rem; }
      .kpi { font-weight:600; font-size:1.1rem; }
      .box { border:1px solid #e5e7eb; border-radius:12px; padding:16px; margin-bottom:16px; }
      .subtle { background:#fafafa; }
      .good { color:#166534; }
      .warn { color:#92400e; }
      .bad  { color:#7f1d1d; }
    "))
  ),
  withMathJax(),
  h2("Bayesian Diagnostic Calculator (Single & Sequential Tests)"),
  div(class="small-note",
      "Educational tool illustrating how prior (prevalence), sensitivity, and specificity combine using Bayes' theorem.",
      "Sequential tests assume conditional independence. Not medical advice."),

  sidebarLayout(
    sidebarPanel(width = 4,
      h4("Global Inputs"),
      div(class="box subtle",
        sliderInput("prior", "Prior probability (prevalence)",
                    min = 0, max = 1, value = 0.05, step = 0.001),
        numericInput("prior_num", NULL, value = 0.05, min = 0, max = 1, step = 0.001),

        sliderInput("Se", "Sensitivity (P(+|D))",
                    min = 0, max = 1, value = 0.95, step = 0.001),
        numericInput("Se_num", NULL, value = 0.95, min = 0, max = 1, step = 0.001),

        sliderInput("Sp", "Specificity (P(-|¬D))",
                    min = 0, max = 1, value = 0.98, step = 0.001),
        numericInput("Sp_num", NULL, value = 0.98, min = 0, max = 1, step = 0.001),

        sliderInput("cohort", "Example cohort size (for counts)", min = 1000, max = 200000,
                    value = 10000, step = 1000)
      ),

      h4("Single Test"),
      div(class="box subtle",
        radioButtons("single_outcome", "Observed outcome", c("Positive","Negative"),
                     selected = "Positive", inline = TRUE)
      ),

      h4("Sequential Tests"),
      div(class="box subtle",
        checkboxInput("same_params", "Use same Se/Sp for all steps", TRUE),
        sliderInput("n_tests", "Number of tests", min = 0, max = 6, value = 2, step = 1),
        uiOutput("seq_controls") # dynamically build per-test inputs
      )
    ),

    mainPanel(width = 8,
      tabsetPanel(type = "tabs",
        tabPanel("How it works",
          br(),
          h4("Bayes’ Theorem for a Diagnostic Test"),
          helpText(HTML('
            For a test with sensitivity \\(\\text{Se} = P(+|D)\\) and specificity
            \\(\\text{Sp} = P(-|\\neg D)\\), and a prior (prevalence) \\(p = P(D)\\):
            <div style="padding:8px 12px; border-left:4px solid #ddd; margin:8px 0;">
              <b>Posterior after a positive test (PPV)</b>:
              \\[
                P(D\\mid +) = \\frac{\\text{Se}\\, p}{\\text{Se}\\, p + (1-\\text{Sp})(1-p)}
              \\]
              <b>Posterior after a negative test (1 - NPV)</b>:
              \\[
                P(D\\mid -) = \\frac{(1-\\text{Se})\\, p}{(1-\\text{Se})\\, p + \\text{Sp}(1-p)}
              \\]
            </div>
            Likelihood ratios (LR) are convenient for chaining multiple tests:
            \\[
              \\text{LR}^+ = \\frac{\\text{Se}}{1-\\text{Sp}},\\qquad
              \\text{LR}^- = \\frac{1-\\text{Se}}{\\text{Sp}}.
            \\]
            Convert prior probability \\(p\\) to odds \\(o = p/(1-p)\\), multiply by LR,
            then convert back: \\(p\' = o\'/(1+o\')\\).
            When tests are independent, multiply their LRs in sequence.
          ')),
          tags$hr(),
          div(class="small-note",
              "Tip: People often overestimate PPV when prevalence is low. This app lets you see how a small prior can dominate even with a very accurate test.")
        ),

        tabPanel("Single Test",
          br(),
          uiOutput("single_summary"),
          tags$hr(),
          h4("Example Counts (Cohort)"),
          tableOutput("single_counts"),
          tags$hr(),
          h4("PPV vs Prevalence (current Se/Sp)"),
          plotOutput("ppv_plot", height = 300)
        ),

        tabPanel("Sequential Tests",
          br(),
          uiOutput("seq_summary"),
          tags$hr(),
          tableOutput("seq_table"),
          plotOutput("seq_plot", height = 300),
          tags$hr(),
          div(class="small-note",
              "Assumes conditional independence between tests; real-world correlations can change results.")
        )
      )
    )
  )
)

# ---------- Server -------------------------------------------------------------

server <- function(input, output, session) {

  # keep sliders and numeric inputs in sync
  observeEvent(input$prior,  ignoreInit = TRUE, {
    updateNumericInput(session, "prior_num", value = input$prior)
  })
  observeEvent(input$prior_num, ignoreInit = TRUE, {
    updateSliderInput(session, "prior", value = clamp01(input$prior_num))
  })
  observeEvent(input$Se, ignoreInit = TRUE, {
    updateNumericInput(session, "Se_num", value = input$Se)
  })
  observeEvent(input$Se_num, ignoreInit = TRUE, {
    updateSliderInput(session, "Se", value = clamp01(input$Se_num))
  })
  observeEvent(input$Sp, ignoreInit = TRUE, {
    updateNumericInput(session, "Sp_num", value = input$Sp)
  })
  observeEvent(input$Sp_num, ignoreInit = TRUE, {
    updateSliderInput(session, "Sp", value = clamp01(input$Sp_num))
  })

  # Build dynamic controls for sequential tests
  output$seq_controls <- renderUI({
    n <- input$n_tests %||% 0
    if (n <= 0) return(NULL)

    # If same_params = TRUE we only need per-step outcome switches.
    if (isTRUE(input$same_params)) {
      tagList(
        lapply(seq_len(n), function(i) {
          fluidRow(
            column(12, radioButtons(
              paste0("out_", i), paste0("Test #", i, " outcome"),
              c("Positive","Negative"), selected = "Positive", inline = TRUE
            ))
          )
        })
      )
    } else {
      # Per-step Se/Sp and outcome
      tagList(
        lapply(seq_len(n), function(i) {
          fluidRow(
            column(12, h5(paste("Test #", i))),
            column(4, sliderInput(paste0("Se_", i), "Sensitivity",
                                   min = 0, max = 1, value = input$Se, step = 0.001)),
            column(4, sliderInput(paste0("Sp_", i), "Specificity",
                                   min = 0, max = 1, value = input$Sp, step = 0.001)),
            column(4, radioButtons(paste0("out_", i), "Outcome",
                                   c("Positive","Negative"), selected = "Positive", inline = TRUE))
          )
        })
      )
    }
  })

  # ---- Single test outputs ----

  output$single_summary <- renderUI({
    p  <- input$prior   %||% 0.05
    Se <- input$Se      %||% 0.95
    Sp <- input$Sp      %||% 0.98
    out <- input$single_outcome %||% "Positive"

    post_pos <- ppv(p, Se, Sp)
    post_neg <- 1 - npv(p, Se, Sp)

    # Choose displayed posterior depending on observed outcome
    post <- if (identical(out, "Positive")) post_pos else post_neg
    ppv_txt <- if (is.na(post_pos)) "NA" else fmt_pct(post_pos)
    npv_txt <- if (is.na(post_neg)) "NA" else fmt_pct(1 - post_neg)

    # Likelihood ratios
    lrp <- lr_pos(Se, Sp); lrn <- lr_neg(Se, Sp)

    HTML(sprintf('
      <div class="box">
        <div class="kpi">
          <div>Prior: <b>%s</b></div>
          <div>Sensitivity: <b>%s</b> &nbsp; Specificity: <b>%s</b></div>
          <div>LR⁺: <b>%s</b> &nbsp; LR⁻: <b>%s</b></div>
        </div>
        <hr/>
        <div>
          <b>Posterior if Positive</b> (PPV): %s<br/>
          <b>Posterior if Negative</b> (P(D|−)): %s
        </div>
        <div style="margin-top:8px;">
          <span class="%s">Observed outcome: %s ⇒ Posterior: <b>%s</b></span>
        </div>
      </div>
    ',
      fmt_pct(p), fmt_pct(Se), fmt_pct(Sp),
      if (is.infinite(lrp)) "∞" else sprintf("%.3f", lrp),
      if (is.infinite(lrn)) "∞" else sprintf("%.3f", lrn),
      ppv_txt,
      if (is.na(post_neg)) "NA" else fmt_pct(post_neg),
      if (identical(out,"Positive")) "good" else "bad",
      out,
      if (is.na(post)) "NA" else fmt_pct(post)
    ))
  })

  output$single_counts <- renderTable({
    p  <- input$prior   %||% 0.05
    Se <- input$Se      %||% 0.95
    Sp <- input$Sp      %||% 0.98
    N  <- input$cohort  %||% 10000
    confusion_matrix(p, Se, Sp, N)
  }, bordered = TRUE, striped = TRUE, spacing = "m", align = "c", digits = 0)

  output$ppv_plot <- renderPlot({
    Se <- input$Se %||% 0.95
    Sp <- input$Sp %||% 0.98
    prev <- seq(0, 1, length.out = 251)
    y <- vapply(prev, function(p) ppv(p, Se, Sp), numeric(1))
    df <- data.frame(Prevalence = prev, PPV = y)
    ggplot(df, aes(Prevalence, PPV)) +
      geom_line(size = 1) +
      scale_x_continuous(labels = scales::percent_format(accuracy = 1)) +
      scale_y_continuous(labels = scales::percent_format(accuracy = 1), limits = c(0,1)) +
      labs(title = "PPV vs Prevalence", subtitle = "Holding Sensitivity/Specificity fixed",
           x = "Prevalence (prior P(D))", y = "PPV = P(D|+)") +
      theme_minimal(base_size = 13)
  })

  # ---- Sequential tests ----

  seq_tests <- reactive({
    n <- input$n_tests %||% 0
    if (n <= 0) return(list())

    if (isTRUE(input$same_params)) {
      Se <- input$Se %||% 0.95
      Sp <- input$Sp %||% 0.98
      lapply(seq_len(n), function(i) {
        list(Se = Se, Sp = Sp, outcome = input[[paste0("out_", i)]] %||% "Positive")
      })
    } else {
      lapply(seq_len(n), function(i) {
        list(
          Se = input[[paste0("Se_", i)]] %||% (input$Se %||% 0.95),
          Sp = input[[paste0("Sp_", i)]] %||% (input$Sp %||% 0.98),
          outcome = input[[paste0("out_", i)]] %||% "Positive"
        )
      })
    }
  })

  seq_result <- reactive({
    tests <- seq_tests()
    p0 <- input$prior %||% 0.05
    if (length(tests) == 0) return(NULL)
    update_sequence(p0, tests)
  })

  output$seq_summary <- renderUI({
    df <- seq_result()
    if (is.null(df) || nrow(df) == 0) {
      return(HTML('<div class="box">No tests configured.</div>'))
    }
    p0 <- df$prior[1]
    pf <- tail(df$posterior, 1)
    pos_count <- sum(df$outcome == "Positive")
    neg_count <- sum(df$outcome == "Negative")

    HTML(sprintf('
      <div class="box">
        <div><b>Start prior:</b> %s</div>
        <div>Outcomes: <b>%d× Positive</b>, <b>%d× Negative</b></div>
        <div>Final posterior after %d tests: <span class="%s"><b>%s</b></span></div>
      </div>
    ',
      fmt_pct(p0), pos_count, neg_count, nrow(df),
      if (pf >= p0) "good" else "bad",
      fmt_pct(pf)
    ))
  })

  output$seq_table <- renderTable({
    df <- seq_result()
    if (is.null(df) || nrow(df) == 0) return(NULL)
    data.frame(
      Step = df$step,
      Prior = fmt_pct(df$prior),
      Sens = fmt_pct(df$Se),
      Spec = fmt_pct(df$Sp),
      Outcome = df$outcome,
      `LR Used` = ifelse(df$outcome == "Positive",
                         sprintf("LR+ = %.3f", df$LR),
                         sprintf("LR- = %.3f", df$LR)),
      Posterior = fmt_pct(df$posterior),
      check.names = FALSE
    )
  }, bordered = TRUE, striped = TRUE, spacing = "m", align = "c")

  output$seq_plot <- renderPlot({
    df <- seq_result()
    if (is.null(df) || nrow(df) == 0) return()
    plot_df <- rbind(
      data.frame(step = 0, posterior = df$prior[1]),
      data.frame(step = df$step, posterior = df$posterior)
    )
    ggplot(plot_df, aes(step, posterior)) +
      geom_line(size = 1) +
      geom_point(size = 2) +
      scale_y_continuous(labels = scales::percent_format(accuracy = 1), limits = c(0,1)) +
      scale_x_continuous(breaks = 0:max(plot_df$step)) +
      labs(title = "Posterior Across Sequential Tests",
           x = "Step (0 = prior)", y = "Probability of disease") +
      theme_minimal(base_size = 13)
  })
}

shinyApp(ui, server)


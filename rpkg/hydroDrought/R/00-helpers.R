#' @export

moving_average <- function(x, n, sides = "past")
{
    dict <- c("past" = 1, "center" = 2, "future" = 3)
    if (is.character(sides)) {
        sides <- pmatch(sides, names(dict))
    } else if (is.numeric(sides)) {
        sides <- match(sides, dict)
    }
    if (is.na(sides)) stop("content of argument 'sides' is invalid.")

    sides <- dict[sides]

    if (sides == 3) {
        sides <- 1
        y <- rev(stats::filter(rev(x), filter = rep(x = 1/n, times = n), sides = sides))
    } else {
        y <- stats::filter(x, filter = rep(x = 1/n, times = n), sides = sides)
    }

    # filter() returns a ts-object
    return(as.numeric(y))
}

# .jday <- function(x) {
#     #as.numeric(format(as.Date(x), "%j"))
#
#     # set the year to year 1972 (which is a leap year)
#     year(x) <- 1972
#     return(x)
# }

#' @export
append_group <- function(x, by = c("day", "week", "month", "season", "year"),
                         start = "-01-01", unique.id = FALSE)
{
    by <- match.arg(by, several.ok = TRUE)
    x$time <- as.Date(x$time)
    start <- regmatches(start, regexpr("-.*", start))

    # always calculate the hydrological year, only id is meaningful
    x$year <- as.integer(substring(group_id(x$time, start[1]), 1L, 4L))

    if ("season" %in% by) {
        if (length(start) < 2) {
            warning("There have to be a least two seasons. Specify argument 'start' accordingly.")
        }
        season.id <- group_id(x$time, start)

        x$season <- factor(substr(season.id, 5L, 10L), levels = start)

        # if existing, use names of the group
        nam <- names(start)
        is.named <- length(nam) == length(start) && all(!is.na(nam)) && all(nam != "")
        if (is.named) levels(x$season) <- nam

        if (unique.id) x$season.id <- season.id
    }

    # only week and month are trivial
    f <- c(week = week, month = month)
    for (i in setdiff(by, c("year", "season", "day"))) {
        #for (i in setdiff(by, c("year", "season"))) {
        x <- mutate(x, !!i := f[[i]](x$time))
        if (unique.id) x[[paste0(i, ".id")]] <- paste(x$year, x[[i]], sep = "-")
    }

    # treat day differently, we need to pass the start of the year
    if ("day" %in% by) {
        x <- mutate(x, day = monthDay(x$time, origin = start[1]))
        if (unique.id)  x <- mutate(x, day.id = as.integer(x$day))
    }

    return(x)
}

#' @export
group_id <- function(time, starts)
{
    starts <- regmatches(starts, regexpr("-.*", starts))

    # all relevant years of the time series
    # first season break could be in the year before
    year <- sort(unique(year(time)))
    year <- c(year, min(year) - 1, max(year) + 1)

    # paste years with season starts
    # vectorized comparison is quite fast
    breaks <- sort(as.Date(outer(year, starts, paste0)))
    season <- outer(time, breaks, ">=")

    return(breaks[rowSums(season)])
}

#' @export
var_threshold <- function(x, vary.by = c("day", "week", "month", "season", "year"),
                          fun, start = "-01-01", append = FALSE, ...)
{
    vary.by <- match.arg(vary.by)
    y <- append_group(x, by = vary.by, start = start)

    if (vary.by == "day") {
        # interpolate Feb 29th with "surrounding" days if not a leap year
        leapday <- as.Date("1972-02-29")

        leapdays <- filter(y, day == leapday - 1 | day == leapday + 1,
                           !leap_year(time)) %>%
            group_by(year) %>%
            summarise(discharge = mean(discharge),
                      day = leapday) %>%
            # surrounding values could be NA
            filter(!is.na(discharge))

        y <- bind_rows(y, leapdays) %>%
            # somehow, class gets lost...
            mutate(day = monthDay(day, origin = start))
    }

    threshold <- y %>%
        # summaries with NA values do not make sense, avoids to always specify na.rm = TRUE
        filter(!is.na(discharge)) %>%
        group_by(.dots = vary.by) %>%
        summarise(threshold = fun(discharge, ...))

    if (append) {
        return(left_join(y, threshold, by = vary.by))
    } else {
        return(threshold)
    }
}


#' @export
const_threshold <- function(x, fun, append = FALSE, ...)
{
    threshold <- x %>%
        # summaries with NA values do not make sense, avoids to always specify na.rm = TRUE
        filter(!is.na(discharge)) %>%
        summarise(threshold = fun(discharge, ...))

    if (append) {
        return(left_join(x, threshold, by = vary.by))
    } else {
        return(threshold)
    }
}


.drought_events <- function(x, threshold,
                            pooling = c("none", "moving-average", "sequent-peak", "inter-event"),
                            pooling.pars = list(n = 10, sides = "center",
                                                min.duration = 5, min.vol.ratio = 0.1))
{
    pooling <- match.arg(pooling)

    # give warnings if using default parameters
    # specifing them explicitly silences it

    # todo? use deficit instead of volume

    # todo: make function resislient against NAs
    # NAs always terminate a drought, never pooled over NAs..

    if (pooling == "moving-average") {
        # todo: remove NAs introduced by moving average
        x <- x %>%
            mutate(discharge = moving_average(discharge, n = pooling.pars$n,
                                              sides = pooling.pars$sides))
    }

    if (is.numeric(threshold) && length(threshold == 1)) {
        # append constant threshold to data
        x$threshold <- threshold
    } else {
        # compute the same groups than threshold and join it
        by <- setdiff(colnames(threshold), "threshold")
        origin <- pull(threshold, by)[1]
        x <- x %>%
            append_group(by = by, start = origin) %>%
            left_join(threshold, by = by)
    }

    x <- x %>%
        mutate(volume = -(discharge - threshold) * 86400,
               below.threshold = discharge < threshold,
               under.drought = below.threshold)

    if (pooling == "sequent-peak") {
        # overwriting the column 'under.drought'
        x <- x %>%
            mutate(storage = .storage(x$discharge, threshold = threshold) * 86400,
                   under.drought = storage > 0)
    }

    # assign event numbers, only every second event is drought
    x <- mutate(x, event = .rle_id(under.drought))

    return(x)
}

#' @export
drought_events <- function(x, threshold,
                           pooling = c("none", "moving-average", "sequent-peak", "inter-event"),
                           pooling.pars = list(n = 10, sides = "center",
                                               min.duration = 5, min.vol.ratio = 0.1),
                           full.table = FALSE, relabel.events = TRUE)
{
    pooling <- match.arg(pooling)

    x <- .drought_events(x = x, threshold = threshold,
                         pooling = pooling, pooling.pars = pooling.pars)

    # summarizing each event
    # todo: capture the variables to summarize as quosures and add  spa Variables

    if (pooling == "sequent-peak") {
        # duration and volume are defined differently
        x <- x %>%
            group_by(event) %>%
            summarise(dbt = sum(below.threshold),
                      start = time[1], duration = dbt, end = max(time),
                      qmin = min(discharge), tqmin = time[which.min(discharge)[1]],
                      vbt = sum(volume[below.threshold]), volume = vbt,
                      under.drought = unique(under.drought))
    } else {
        x <- x %>%
            group_by(event) %>%
            summarise(start = time[1], duration = n(), end =  max(time),
                      qmin = min(discharge), tqmin = time[which.min(discharge)[1]],
                      vbt = sum(volume[below.threshold]), volume = sum(volume),
                      dbt = sum(below.threshold),
                      under.drought = unique(under.drought))
    }

    # only keep drought events?
    x <- filter(x, under.drought)

    if (pooling == "inter-event") {
        p <- 1
        x$pool <- 0L

        row <- if (x$under.drought[1]) 1 else 2   # start with first drought
        while (row <= nrow(x)) {
            x$pool[c(row, row + 1)] <- p

            ie.time <- x$duration[row + 1]
            # todo: check if we need to sum only over deficits
            cumvol <- sum(x$volume[x$pool == p & x$under.drought])
            vol.ratio <- cumvol / x$volume[row + 1]

            depended <- ie.time <= pooling.pars$min.duration &&
                vol.ratio < pooling.pars$min.vol.ratio

            if (!depended) p <- p + 1

            row <- row + 2
        }
    }

    if (relabel.events) x <- mutate(x, event = order(event))

    # retain full table?
    if (!full.table) {
        if (pooling == "inter-event") {
            x <- select(x, event, start, end, duration,  volume, tqmin, #dbt,  vbt,
                        qmin, pooled)
        } else {
            x <- select(x, event, start, end, duration, volume, tqmin, #dbt,  vbt,
                        qmin)
        }
    }

    return(x)
}

.storage <- function(discharge, threshold)
{
    x <- data_frame(discharge = discharge,
                    deficit = threshold - discharge,
                    storage = 0)

    x$storage[1] <- if (x$deficit[1] > 0) x$deficit[1] else 0
    for (i in seq(2, nrow(x))) {
        s <- x$storage[i - 1] + x$deficit[i]
        x$storage[i] <- if (s > 0) s else 0
    }

    return(x$storage)
}

# tibble(d = c(1, 1, 0, 0, -1, 0, -1, -1, -1, 1, 1, 1, 1),
#        t = 0,
#        s = .storage(d, t))



.rle_id <- function(x)
{
    cumsum(x != lag(x, default = x[1]))
}



inspect_spa <- function(x)
{
    discharge <- ggplot(x, aes(time, discharge)) +
        geom_line() +
        geom_point(size = 0.5) +
        geom_hline(yintercept = q90, col = 2, linetype = "dashed", size = 0.2) +
        facet_wrap(~event, scales = "free", nrow = 1)

    storage <- ggplot(x, aes(time, storage)) +
        geom_line() +
        geom_point(size = 0.5) +
        expand_limits(y = 0) +
        facet_wrap(~event, scales = "free", nrow = 1)

    cowplot::plot_grid(discharge, storage, align = "v", ncol = 1)
}

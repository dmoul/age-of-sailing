# load-voyages

###### Prepare port data

ports_normalized <- read_csv(here("data/ports-enriched4.csv"),
                             show_col_types = FALSE) %>%
  mutate( across(.cols = c(port2, level2, country), ~str_trim(str_to_lower(.x)) ) ) |>
  arrange(port2, country, level2) |>
  fill(country, .direction = "down") |>
  distinct(port2, country, level2, direction, port, .keep_all = TRUE)

port_lon_lat <- read_csv(here("data/port_lon_lat.csv"),
                         show_col_types = FALSE) %>%
  mutate( across(.cols = c(port2, level2, country), ~str_trim(str_to_lower(.x)) ) ) %>%
  filter(!is.na(port2))

df_ports <- left_join(ports_normalized, port_lon_lat, by = "port2") %>%
  mutate_if(is.character, ~map_chr(.x, iconv, "UTF-8", "UTF-8", sub='')) %>% # just in case
  mutate(level2 = coalesce(level2.x, level2.y),
         country = coalesce(country.x, country.y)) %>%
  select(-ends_with(c(".x", ".y")))


###### get (or prepare) all_voyages ######

fname_cliwoc21 <- here("data/processed/cliwoc21-cleaned.rds")

if( file.exists(fname_cliwoc21) ) {
  all_voyages <- read_rds(fname_cliwoc21)
} else {
  all_voyages_raw <- read_csv("https://blogsimoncoulombe.s3.amazonaws.com/cliwoc/cliwoc21.csv", #"./data/cliwoc21.csv",
                            guess_max = 200000) %>%
    filter(!str_detect(YR, "GIS|VIE"),
           !is.na(VoyageIni),
           !is.na(VoyageFrom),
           !is.na(VoyageTo),
           !is.na(longitude),
           !is.na(latitude)
    )  %>%
    mutate(ObsDate = ymd(paste0(Year, "-", Month, "-", Day)),
           longitude = as.numeric(longitude),
           latitude = as.numeric(latitude),
           VoyageIni = ymd(VoyageIni),
           VoyageFrom = str_remove_all(VoyageFrom, "[.]"), # remove fullstops, which aren't used consistently
           VoyageTo = str_remove_all(VoyageTo, "[.]"), # remove fullstops
           ShipName = str_remove_all(ShipName, "[.]"), # remove fullstops
           Company = str_remove_all(Company, "[.]") # remove fullstops
    ) %>%
    filter(!is.na(ObsDate)) %>% # remove seven rows with bad dates
    rename(ObsTime = TimeOB) %>%
    # keep only the columns we are likely to use
    select(ShipName, ObsDate, ObsTime, Year, Month, Day, longitude, latitude, 
           starts_with("Voyage"), Nationality, ShipType, Company) %>%
    # use this id later for error removal/correction
    arrange(ShipName, ObsDate) %>%
    mutate(id = row_number())
  
  ###### keep only one observation per day per ship voyage ###### 
  # where there are multiple, it seems there are duplicate logs
  # the vast majority of observations are at local noon, so it's not typically an issue of multiple obs on same day
  # it's probably possible to be apply better heuristics when deciding which of the duplicate observations to keep
  mult_obs <- all_voyages_raw %>%
    group_by(ShipName, VoyageIni, ObsDate) %>%
    summarize(n_obs = n()) %>%
    ungroup() %>%
    filter(n_obs > 1)
  
  all_voyages_raw <- left_join(all_voyages_raw,
                         mult_obs,
                         by = c("ShipName", "VoyageIni", "ObsDate")) %>%
    arrange(ShipName, ObsDate) %>%
    distinct(ShipName, ObsDate, .keep_all = TRUE) %>%
    select(-n_obs)
  
  ###### remove bad points ######
  
  # TODO: this could move up to where we define cliwoc21-cleaned.rds so it only needs to be run once
  # before doing that, need to make sure it's useful to remove single bad points (what about the subsequent points?)
  # see for example montevideo
  
  get_dist <- function(df) {
    # INPUT: list-column with df containing longitude, latitude, id for one ship voyage
    # OUTPUT: same with addition of distance_km column
    
    # debug
    # message("id: ", glue_collapse(df$id, sep = " "))
    # message("  n_id: ", length(df$id))
    
    xx <- df %>%
      st_as_sf(coords = c("longitude", "latitude"),
               crs = "WGS84") %>% # results in distances in meters
      st_distance(by_element = FALSE)
    # now we have a matrix of distances between all points; we only want sequential points
    # ie (i+1, i) for point i
    distance_m <- double(nrow(df))
    distance_m[[1]] <- NA_real_
    if (nrow(xx) > 1) {
      for (i in 2:nrow(xx)) {
        distance_m[[i]] <- xx[i, i-1]
      }
    }
    distance_m / 1000 # easier to work in km
  }
  
  # adding distance_km, following pattern at https://stackoverflow.com/questions/46436107/how-to-add-calculated-columns-to-nested-data-frames-list-columns-using-purrr
  test_bad_points_temp <- all_voyages_raw %>%
    filter(
      # TODO: is.na() checks here are probably redundant; check and remove them
      !is.na(longitude),
      !is.na(latitude),
      !is.na(VoyageFrom),
      !is.na(VoyageTo)
    )
  
  test_bad_points_temp2 <- test_bad_points_temp %>%
    select(id, ShipName, VoyageIni, VoyageFrom, VoyageTo, ObsDate, longitude, latitude) %>%
    group_by(ShipName, VoyageIni, VoyageFrom, VoyageTo) %>%
    nest_legacy()
  
  ## this works with get_dist() function above
  test_bad_points_temp3 <- test_bad_points_temp2 %>%
    mutate(data = map(data,
                      ~ mutate(.x,
                               distance_km  = get_dist(.x)
                      )
    )
    ) %>%
    unnest(c(data))
  
  # Now find unusually large distance_km, which indicate issues
  # * try simply deleting the offending points. Is that good enough? Yes
  # * To be more sophisticated, we could iterate on the subsequent points until we find one close enough. 
  #     If there's in any, the last good point is the one before the first offending point.)
  # * Do we need to consider whether any days are missing in the logs to decide whether to remove the point? No
  probably_bad <- test_bad_points_temp3 %>%
    filter(distance_km > 1000)
  
  all_voyages_temp <- anti_join(all_voyages_raw,
                        probably_bad %>% select(id),
                        by = "id") %>%
    left_join(.,
              test_bad_points_temp3 %>% select(id, distance_km),
              by = "id")
  
  all_voyages_temp2 <- all_voyages_temp %>% # TODO: make it _raw before finalizing
    mutate(dist_temp = distance_km) %>%
    replace_na(list(dist_temp = 0)) %>%
    group_by(ShipName, VoyageIni, VoyageFrom, VoyageTo) %>%
    summarize(date_first = min(ObsDate),
              date_last = max(ObsDate),
              n_days = difftime(date_last, date_first, units = "days"),
              n_obs = n(),
              day_counter = row_number(),
              cum_distance = cumsum(dist_temp),
              id = id,
              ObsDate = ObsDate
              ) %>%
    ungroup() %>%
    mutate(
      n_days = as.double(n_days),
      days_enroute = difftime(ObsDate, date_first, units = "days"),
      days_enroute = as.double(days_enroute),
      ObsDate_last = lag(ObsDate)
    )
  
  all_voyages <- left_join(
    all_voyages_temp,
    all_voyages_temp2 %>%
      select(id, ShipName, date_first:cum_distance, days_enroute, ObsDate_last),
    by = c("id", "ShipName")
  )
  
  write_rds(all_voyages, file = fname_cliwoc21)
  
} # end get all_voyages

df_voyages <- all_voyages %>%
  filter(
    Year >= 1750, # start of main data set; remove some earlier year outliers
    Year <= 1815  # through the end of the Napoleonic Wars
  ) %>%
  left_join(.,
            color_routes,
            by = "Nationality") %>%
  mutate(Nationality = factor(Nationality, levels = color_routes$Nationality))

# disambiguate and correct some entries
df_voyages$VoyageFrom[df_voyages$ShipName == "CROCODILE" & df_voyages$VoyageIni == ymd("1782-10-15")] <- "TORBAY NF"
df_voyages$VoyageFrom[df_voyages$ShipName == "WARWICK" & df_voyages$VoyageIni == ymd("1777-08-17")] <- "TORBAY NF"
df_voyages$VoyageTo[df_voyages$ShipName == "SOMERSET" & df_voyages$VoyageIni == ymd("1776-01-15")] <- "TORBAY NF"
df_voyages$VoyageFrom[df_voyages$ShipName == "SWALLOW" & df_voyages$VoyageIni == ymd("1750-03-21")] <- "CALCUTTA"
df_voyages$longitude[df_voyages$ShipName == "PODEROSO" & df_voyages$VoyageIni == ymd("1777-12-19")] <- -44.8 # was 111 (near Australia)

# add port_from and port_to columns, making use of port name normalization (port2)

df_voyages <- df_voyages %>%
  left_join(., 
            inner_join(.,
                       df_ports %>% select(port2, port, country),
                       by = c("VoyageFrom" = "port")
            ) %>%
              transmute(id = id,
                        port_from = port2,
                        country_from = country) %>%
              distinct(id, port_from, country_from),
            by = "id") %>%
  left_join(.,
            inner_join(.,
                       df_ports %>% select(port2, port, country),
                       by = c("VoyageTo" = "port")
            ) %>%
              transmute(id = id,
                        port_to = port2,
                        country_to = country) %>%
              distinct(id, port_to, country_to),
            by = "id")

# remove voyages too short to be interesting
df_voyages <- anti_join(df_voyages, 
                        df_voyages %>%
                          group_by(ShipName, VoyageIni, VoyageFrom, VoyageTo) %>%
                          summarize(n_obs = n()) %>%
                          ungroup() %>%
                          filter(n_obs < MIN_VOYAGE_DURATION), # TODO: better would be n_days, not n_obs
                        by = c("ShipName", "VoyageIni", "VoyageFrom", "VoyageTo")
)

# remove multiple observations on same day of c(ShipName, VoyageIni)
# TODO ... check if it's done elsewhere

# add days_since_last_obs
df_voyages <- df_voyages %>%
  group_by(ShipName, VoyageIni) %>%
  mutate(days_since_last_obs = difftime(ObsDate, ObsDate_last, units = "days")) %>%
  ungroup() %>%
  mutate(days_since_last_obs = ifelse(days_enroute == 0, NA, days_since_last_obs))

# remove ships with breaks in voyage > 1000 days
df_voyages <- df_voyages %>%
  filter(!ShipName %in% c("DESCONOCIDO-06", "SCOURGE"))


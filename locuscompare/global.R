library(shiny)
library(DT)
library(stringr)
library(dplyr)
library(RMySQL)
library(pool)
library(DBI)
library(foreach)
library(zip)
library(shinyjs)
source('locuscompare.R')
source('config/config.R')
library(digest)
library(utils)
library(googlesheets4)
library(promises)
library(future)
plan (multisession)
library(mailR)
library(shinycssloaders)
library(googledrive)
library(manhattan)
library(shinythemes)

# Variables:
locuscompare_pool = dbPool(
    RMySQL::MySQL(), 
    dbname = "locuscompare",
    host = aws_host,
    username = aws_username,
    password = aws_password,
    minSize = 4
)

onStop(function() {
  poolClose(locuscompare_pool)
})

args = list(
    drv = RMySQL::MySQL(),
    dbname = "locuscompare",
    host = aws_host,
    username = aws_username,
    password = aws_password
)
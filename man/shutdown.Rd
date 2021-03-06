% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/connections.R
\name{shutdown}
\alias{shutdown}
\title{Shutdown the anchors java server.}
\usage{
shutdown(control = NULL)
}
\arguments{
\item{control}{Object of class \code{anchors_control}. Must have a slot \code{connection} representing a socketConnection.}
}
\value{
this method will shutdown the socketConnection and return a nullified control object.
}
\description{
Attempts to shutdown a running Anchors instance.
}

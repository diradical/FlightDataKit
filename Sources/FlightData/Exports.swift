// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

// What an app needs of the format to write report types comes with FlightData. Sealing, archives and keys stay in
// FlightDataFormat, for tools that open reports.
@_exported import struct FlightDataFormat.AppInfo
@_exported import struct FlightDataFormat.FieldDescription
@_exported import enum FlightDataFormat.FieldKind
@_exported import struct FlightDataFormat.ReportContent
@_exported import struct FlightDataFormat.ReportFile
@_exported import enum FlightDataFormat.ReportKind
@_exported import enum FlightDataFormat.ReportLimits
@_exported import struct FlightDataFormat.ReportValidationError
@_exported import enum FlightDataFormat.ReportValue

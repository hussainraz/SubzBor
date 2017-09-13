unit uProbe;
{ SubzBor: Free subtitle cutting tool with the help of FFmpeg and MKVToolNix

  Copyright (C) 2017 Mohammadreza Bahrami m.audio91@gmail.com

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <http://www.gnu.org/licenses/>.
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Process, UTF8Process, uTimeSlice, CommonStrUtils,
  CommonFileUtils, uSBConst;

type

  { TSubzBorProbeInfo }

  TSubzBorProbeInfo = record
    ToolsFolder: String;
    FFmpeg: String;
    MkvMerge: String;
    MkvExtract: String;
    InputFile: String;
    TimeSlices: String;
  end;

  { TSubzBorProbeResult }

  TSubzBorProbeResult = record
    ToolsFolderValid: Boolean;
    FFmpegValid: Boolean;
    MkvMergeValid: Boolean;
    MkvExtractValid: Boolean;
    InputFileValid: Boolean;
    InputFileIsText: Boolean;
    TimeSlicesValid: Boolean;
    DummyVidExists: Boolean;
    SubzBorPath: String;
    LastError: String;
  end;

  { TSubzBorProbeThread }

  TSubzBorProbeThread = class(TThread)
  private
    FProbeInfo: TSubzBorProbeInfo;
    FProbeResult: TSubzBorProbeResult;
    FOnProbeDone: TThreadMethod;
    function RunCaptureCmd(const Exec, Cmd: String): String;
    procedure ValidateToolsFolder;
    procedure ValidateFFmpeg;
    procedure ValidateInputFile;
    procedure ValidateTimeSlices;
    procedure ValidateDummyVid;
    procedure ValidateMkvMerge;
    procedure ValidateMkvExtract;
  protected
    procedure Execute; override;
  public
    property OnProbeDone: TThreadMethod read FOnProbeDone write FOnProbeDone;
    property ProbeResult: TSubzBorProbeResult read FProbeResult;
    constructor Create(const ProbeInfo: TSubzBorProbeInfo);
    destructor Destroy; override;
  end;

const
  FFmpegValidationCmd = '-version';
  MkvMergeValidationCmd = '-h';
  MkvExtractValidationCmd = '-h';
  FileValidationCmd = '-hide_banner -i %i%';
  ValidTxtSubs: array[0..6] of String = ('ass', 'srt', 'ssa', 'subrip', 'webvtt', 'sami', 'stl');
  ValidImgSubs: array[0..1] of String = ('dvd_subtitle', 'hdmv_pgs_subtitle');
  ValidFFmpegHas: array[0..1] of String = ('ffmpeg version', '--enable-iconv');
  ValidFFmpegHasNot: array[0..3] of String = ('--disable-muxers', '--disable-demuxers', '--disable-encoders', '--disable-decoders');
  ValidMkvMergeHas: array[0..1] of String = ('--ui-language', '--fourcc');
  ValidMkvExtractHas: array[0..1] of String = ('--ui-language', 'Timecode extraction:');
  ValidFileHas = 'Subtitle:';
  ValidDummyVidHas: array[0..3] of String = ('04:00:00.00', '16x16', '60 fps', 'zlib');

implementation

{ TSubzBorProbeThread }

function TSubzBorProbeThread.RunCaptureCmd(const Exec, Cmd: String): String;
const
  BUF_SIZE = 1024;
var
  Proc: TProcessUTF8;
  Mem: TBytesStream;
  BytesRead: LongInt;
  Buffer: array[1..BUF_SIZE] of Byte;
  i: Integer;
begin
  Result := EmptyStr;
  Proc := TProcessUTF8.Create(nil);
  Mem := TBytesStream.Create;
  try
    with Proc do
    begin
      Executable := Exec;
      Options := Options+[poUsePipes,poNoConsole,poStderrToOutPut];
      PipeBufferSize := BUF_SIZE;
      with Parameters do
      begin
        StrictDelimiter := True;
        Delimiter := ' ';
        DelimitedText := NoChainedSpaces(Cmd);
        for i := 0 to Count-1 do
          Strings[i] := DeEscape(Strings[i]);
      end;
      Execute;
      repeat
        BytesRead := Output.Read(Buffer, BUF_SIZE);
        Mem.Write(Buffer[1], BytesRead);
      until BytesRead = 0;
      Mem.Position := 0;
      Result := String(PChar(Mem.Bytes));
    end;
  finally
    if Assigned(Proc) then
      Proc.Free;
    if Assigned(Mem) then
      Mem.Free;
  end;
end;

procedure TSubzBorProbeThread.ValidateToolsFolder;
var
  s: String;
begin
  if not DirectoryExists(FProbeInfo.ToolsFolder) then Exit;
  s := ExtractFilePath(ExcludeTrailingPathDelimiter(FProbeInfo.ToolsFolder));
  s := IncludeTrailingPathDelimiter(s);
  {$IFDEF WINDOWS}
  if not FileExists(s+'subzbor.exe') then Exit;
  {$ENDIF}
  {$IFDEF UNIX}
  if not FileExists(s+'subzbor') then Exit;
  {$ENDIF}
  FProbeResult.ToolsFolderValid := TryDirectoryIsWritable(s);
  FProbeResult.SubzBorPath := s;
end;

procedure TSubzBorProbeThread.ValidateFFmpeg;
var
  s,t: String;
begin
  s := RunCaptureCmd(FProbeInfo.FFmpeg, FFmpegValidationCmd);
  FProbeResult.FFmpegValid := True;
  for t in ValidFFmpegHas do
    if s.IndexOf(t) < 0 then
    begin
      FProbeResult.FFmpegValid := False;
      Break;
    end;
  for t in ValidFFmpegHasNot do
    if s.IndexOf(t) >= 0 then
    begin
      FProbeResult.FFmpegValid := False;
      Break;
    end;
end;

procedure TSubzBorProbeThread.ValidateInputFile;
var
  s,t,Cmd: String;
  i: Integer;
begin
  if (FProbeInfo.InputFile + wSubzBor + wTemp).Length > 254 then Exit;
  t := QuoteAndEscape(FProbeInfo.InputFile);
  Cmd := FileValidationCmd.Replace('%i%', t, []);
  s := RunCaptureCmd(FProbeInfo.FFmpeg, Cmd);
  i := s.IndexOf(ValidFileHas);
  if i >= 0 then
  begin
    s := s.Substring(i+ValidFileHas.Length, (' hdmv_pgs_subtitle ').Length);
    for t in ValidTxtSubs do
      if s.IndexOf(t) >= 0 then
      begin
        FProbeResult.InputFileValid := True;
        FProbeResult.InputFileIsText := True;
        Break;
      end;
    for t in ValidImgSubs do
      if s.IndexOf(t) >= 0 then
      begin
        FProbeResult.InputFileValid := True;
        FProbeResult.InputFileIsText := False;
        Break;
      end;
  end;
end;

procedure TSubzBorProbeThread.ValidateTimeSlices;
var
  tsl: TTimeSliceList;
begin
  tsl.ExtendedValue := FProbeInfo.TimeSlices;
  FProbeResult.TimeSlicesValid := tsl.Incremental;
end;

procedure TSubzBorProbeThread.ValidateDummyVid;
var
  s,t,Cmd: String;
begin
  if not FProbeResult.ToolsFolderValid then Exit;
  t := Escape(FProbeInfo.ToolsFolder + 'dummyvid.avi');
  Cmd := FileValidationCmd.Replace('%i%', t, []);
  s := RunCaptureCmd(FProbeInfo.FFmpeg, Cmd);
  for t in ValidDummyVidHas do
    if s.IndexOf(t) < 0 then
      Exit;
  FProbeResult.DummyVidExists := True;
end;

procedure TSubzBorProbeThread.ValidateMkvMerge;
var
  s,t: String;
begin
  s := RunCaptureCmd(FProbeInfo.MkvMerge, MkvMergeValidationCmd);
  FProbeResult.MkvMergeValid := True;
  for t in ValidMkvMergeHas do
    if s.IndexOf(t) < 0 then
    begin
      FProbeResult.MkvMergeValid := False;
      Break;
    end;
end;

procedure TSubzBorProbeThread.ValidateMkvExtract;
var
  s,t: String;
begin
  s := RunCaptureCmd(FProbeInfo.MkvExtract, MkvExtractValidationCmd);
  FProbeResult.MkvExtractValid := True;
  for t in ValidMkvExtractHas do
    if s.IndexOf(t) < 0 then
    begin
      FProbeResult.MkvExtractValid := False;
      Break;
    end;
end;

procedure TSubzBorProbeThread.Execute;
begin
  try
    ValidateToolsFolder;
    ValidateFFmpeg;
    ValidateInputFile;
    ValidateTimeSlices;
    ValidateDummyVid;
    ValidateMkvMerge;
    ValidateMkvExtract;
  except
    on E: Exception do
      FProbeResult.LastError := E.Message;
  end;
end;

constructor TSubzBorProbeThread.Create(const ProbeInfo: TSubzBorProbeInfo);
begin
  inherited Create(True);
  FProbeInfo := ProbeInfo;
  FProbeInfo.ToolsFolder := IncludeTrailingPathDelimiter(FProbeInfo.ToolsFolder);
  FProbeInfo.TimeSlices := Trim(FProbeInfo.TimeSlices);
  FreeOnTerminate := True;
end;

destructor TSubzBorProbeThread.Destroy;
begin
  if Assigned(OnProbeDone) then
    Synchronize(OnProbeDone);
  FProbeInfo := Default(TSubzBorProbeInfo);
  FProbeResult := Default(TSubzBorProbeResult);
  inherited Destroy;
end;

end.

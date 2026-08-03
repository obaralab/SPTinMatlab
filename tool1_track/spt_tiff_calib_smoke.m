function spt_tiff_calib_smoke()
%SPT_TIFF_CALIB_SMOKE  Auto must read a Fiji-saved TIFF, and must refuse to guess.
%
% The failure this pins: spt_pixel_size read only XResolution + ResolutionUnit and bailed out when
% ResolutionUnit was None — which is exactly how ImageJ/Fiji writes a calibrated file. Fiji puts the
% SCALE in XResolution and the UNIT in a text block in ImageDescription, so the one case Auto most
% needed to handle was the one it rejected.
%
% The other half matters just as much: a wrong pixel size silently rescales every distance, area and
% diffusion coefficient downstream, so anything not actually readable must come back NaN rather than
% a plausible-looking default.

here = fileparts(mfilename('fullpath')); addpath(here);
tmp = fullfile(tempdir,'spt_tiff_calib_smoke'); if isfolder(tmp), rmdir(tmp,'s'); end
mkdir(tmp);
im = uint16(1000*rand(16));

% ---- 1. a Fiji-style file: scale in XResolution, unit in ImageDescription, ResolutionUnit None ---
f1 = fullfile(tmp,'fiji.tif');
desc = sprintf('ImageJ=1.54f\nimages=5703\nframes=5703\nunit=micron\nfinterval=0.010519135743379593\nloop=false\nmin=131.0\nmax=1904.0\n');
write_tif(f1, im, 6.25, 1, desc);            % ResolutionUnit 1 = None
c = spt_tiff_calib(f1);
fprintf('fiji-style : px %.6g (%s)  dt %.9g (%s)  disp %g-%g\n', c.pixUm,c.src.pixUm,c.dt_s,c.src.dt_s,c.dispLo,c.dispHi);
assert(abs(c.pixUm - 0.16)/0.16 < 1e-4, 'micron unit + XResolution 6.25 must give 0.16 um/px, got %.12g', c.pixUm);
assert(abs(c.dt_s - 0.010519135743379593) < 1e-15, 'finterval was not read');   % text, so exact
assert(c.dispLo==131 && c.dispHi==1904, 'the stored display range was not read');
assert(strcmp(c.src.pixUm,'imagej'), 'provenance should say imagej');
assert(c.nFrames==5703, 'frame count not read');
% the old reader is exactly the thing that failed here
assert(isempty(spt_pixel_size(f1)), 'fixture no longer reproduces the original failure');

% ---- 2. nanometres, so the unit table is actually used ------------------------------------------
f2 = fullfile(tmp,'nm.tif');
write_tif(f2, im, 6.25, 1, sprintf('ImageJ=1.54f\nunit=nm\n'));
c2 = spt_tiff_calib(f2);
assert(isnan(c2.pixUm), 'nm/6.25 = 0.00016 um/px is below any real microscope and must be refused');

f2b = fullfile(tmp,'nm2.tif');
write_tif(f2b, im, 0.00625, 1, sprintf('ImageJ=1.54f\nunit=nm\n'));   % 160 nm/px
c2b = spt_tiff_calib(f2b);
fprintf('nanometres : px %.6g (%s)\n', c2b.pixUm, c2b.src.pixUm);
% TIFF stores XResolution as a RATIONAL (two 32-bit ints), so it does not round-trip to the last
% bit. The tolerance is relative and far below anything experimentally meaningful.
assert(abs(c2b.pixUm - 0.16)/0.16 < 1e-4, '160 nm/px must come back as 0.16 um/px, got %.12g', c2b.pixUm);

% ---- 3. a plain TIFF with real resolution tags must still work (the old path) --------------------
f3 = fullfile(tmp,'plain.tif');
write_tif(f3, im, 10000/0.16, 3, '');        % pixels per cm, ResolutionUnit 3 = cm
c3 = spt_tiff_calib(f3);
fprintf('plain cm   : px %.6g (%s)\n', c3.pixUm, c3.src.pixUm);
assert(abs(c3.pixUm - 0.16)/0.16 < 1e-4, 'the resolution-unit path regressed, got %.12g', c3.pixUm);
assert(strcmp(c3.src.pixUm,'resunit'), 'provenance should say resunit');

% ---- 4. refuse to guess --------------------------------------------------------------------------
f4 = fullfile(tmp,'uncal.tif');
write_tif(f4, im, 1, 1, sprintf('ImageJ=1.54f\nunit=pixel\n'));       % explicitly uncalibrated
c4 = spt_tiff_calib(f4);
assert(isnan(c4.pixUm), 'unit=pixel means UNCALIBRATED and must not produce a number');
assert(isnan(c4.dt_s),  'no finterval must not produce a frame interval');

f5 = fullfile(tmp,'nores.tif');
t = Tiff(f5,'w'); setTag(t,'Photometric',Tiff.Photometric.MinIsBlack);
setTag(t,'ImageLength',16); setTag(t,'ImageWidth',16); setTag(t,'BitsPerSample',16);
setTag(t,'SamplesPerPixel',1);
setTag(t,'PlanarConfiguration',Tiff.PlanarConfiguration.Chunky); write(t,im); close(t);
c5 = spt_tiff_calib(f5);
assert(isnan(c5.pixUm), 'a TIFF with no resolution at all must give NaN, got %g', c5.pixUm);

% ---- 5. finterval=0 is "no time calibration", NOT dt=0 -------------------------------------------
f6 = fullfile(tmp,'zerodt.tif');
write_tif(f6, im, 6.25, 1, sprintf('ImageJ=1.54f\nunit=micron\nfinterval=0\nfps=95.06\n'));
c6 = spt_tiff_calib(f6);
fprintf('finterval=0: dt %.6g (%s)  <- falls through to fps\n', c6.dt_s, c6.src.dt_s);
assert(c6.dt_s > 0 && abs(c6.dt_s - 1/95.06) < 1e-12, 'finterval=0 should fall through to fps, got %g', c6.dt_s);

% ---- 6. hostile metadata must not throw ----------------------------------------------------------
% This parser runs on every cell selection against whatever TIFF the user points at. A vendor block
% with a digit-leading key used to take down dynamic-field assignment; over-long keys only warn.
f8 = fullfile(tmp,'junk.tif');
write_tif(f8, im, 6.25, 1, sprintf('ImageJ=1.54f\nunit=micron\n2016=vendor junk\n99bottles=x\n=novalue\nnoequals\n'));
c8 = spt_tiff_calib(f8);
assert(abs(c8.pixUm - 0.16)/0.16 < 1e-4, 'a digit-leading key broke the parse');

% ---- 7. the micro sign arrives as UTF-8, not as one char ------------------------------------------
% ImageJ rewrites a typed 'um' to U+00B5 and writes the block in the platform charset, so a file
% calibrated by hand in Image > Properties reaches us as two bytes.
for u = {char([194 181]), char([206 188]), 'u'}
    f9 = fullfile(tmp,'utf.tif');
    write_tif(f9, im, 6.25, 1, ['ImageJ=1.54f' newline 'unit=' u{1} 'm' newline]);
    c9 = spt_tiff_calib(f9);
    assert(abs(c9.pixUm - 0.16)/0.16 < 1e-4, 'unit=%sm was not read as microns', u{1});
end
% ...but a bare 'm' is METRES and must still be refused
f10 = fullfile(tmp,'metres.tif');
write_tif(f10, im, 6.25, 1, sprintf('ImageJ=1.54f\nunit=m\n'));
assert(isnan(subsref(spt_tiff_calib(f10), substruct('.','pixUm'))), ...
       'unit=m is metres — 1e6/6.25 is not a pixel size and must be refused');

% ---- 8. a slow timelapse must not exceed what the app's field accepts ------------------------------
% spt_app's frame-interval field is capped, and Auto assigns straight into it; a finterval the reader
% accepts but the field rejects throws out of Scan.
f11 = fullfile(tmp,'slow.tif');
write_tif(f11, im, 6.25, 1, sprintf('ImageJ=1.54f\nunit=micron\nfinterval=300\n'));
c11 = spt_tiff_calib(f11);
assert(c11.dt_s == 300, 'a 5-minute timelapse interval should be accepted');
src = fileread(fullfile(here,'spt_app.m'));
tok = regexp(src, "eCalDt = uieditfield\([^;]*?'Limits',\[([^\]]*)\]", 'tokens', 'once');
assert(~isempty(tok), 'could not find the frame-interval field limits');
lim = str2double(strsplit(strtrim(tok{1})));
assert(c11.dt_s <= lim(2), ...
    'the reader accepts dt=%g but the app field caps at %g — Auto would throw', c11.dt_s, lim(2));

% ---- 9. a missing file must not throw -------------------------------------------------------------
c7 = spt_tiff_calib(fullfile(tmp,'nope.tif'));
assert(isnan(c7.pixUm) && isnan(c7.dt_s), 'a missing file should return NaNs, not throw');

fprintf('\nALL TIFF CALIBRATION ASSERTIONS PASSED.\n');
end

function write_tif(path, im, xres, resunit, desc)
t = Tiff(path,'w');
setTag(t,'Photometric',Tiff.Photometric.MinIsBlack);   % must precede BitsPerSample
setTag(t,'ImageLength',size(im,1)); setTag(t,'ImageWidth',size(im,2));
setTag(t,'BitsPerSample',16); setTag(t,'SamplesPerPixel',1);
setTag(t,'PlanarConfiguration',Tiff.PlanarConfiguration.Chunky);
setTag(t,'XResolution',xres); setTag(t,'YResolution',xres);
setTag(t,'ResolutionUnit',resunit);
if ~isempty(desc), setTag(t,'ImageDescription',desc); end
write(t,im); close(t);
end

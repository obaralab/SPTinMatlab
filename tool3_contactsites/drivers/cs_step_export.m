function outFile = cs_step_export(CSW, anaDir, opts)
%CS_STEP_EXPORT  Export contact-site member-track trajectories for STEP pointwise-diffusion analysis.
%
%   outFile = cs_step_export(CSW, anaDir)
%   outFile = cs_step_export(CSW, anaDir, opts)   % opts.minLen (default 5), opts.file (default all cells)
%
% Writes analysis/step/step_tracks.csv — one row per localization of every contact-site MEMBER track,
% with an `inside_cs` flag (1 = that localization is inside the site boundary AND in its time window).
% This is the input contract for run_step.py (STEP predicts D(t)/alpha(t) per track); the import side
% (cs_step_import) then compares D INSIDE vs OUTSIDE the site — the diffusion change due to interaction.
%
% Columns: track_uid, file, cellIndex, csID, window, trackCol, frame, t_s, x_um, y_um, inside_cs
%   track_uid = <file>__cs<csID>_w<window>_t<trackCol>  (unique per member track per site)
%
% Also writes step/step_meta.json (dt per cell, units, counts) for the Python side.
if nargin < 3 || ~isstruct(opts), opts = struct(); end
minLen = getf(opts,'minLen',5);
wantFile = getf(opts,'file','');
stepDir = fullfile(anaDir,'step'); if ~isfolder(stepDir), mkdir(stepDir); end
outFile = fullfile(stepDir,'step_tracks.csv');

fid = fopen(outFile,'w'); if fid<0, error('cs_step_export:open','cannot write %s', outFile); end
c = onCleanup(@() fclose(fid));
fprintf(fid,'track_uid,file,cellIndex,csID,window,trackCol,frame,t_s,x_um,y_um,inside_cs\n');

nTk = 0; nRow = 0;
for s = 1:numel(CSW)
    e = CSW(s);
    if ~isempty(wantFile) && ~strcmp(char(e.file), wantFile), continue; end
    if isempty(e.tracks) || ~isfield(e,'CSmatrix') || isempty(e.CSmatrix), continue; end
    dt = getf(e,'dt',0.02); cx = e.center(1); cy = e.center(2); rb = e.refboundary;
    for jj = 1:numel(e.tracks)
        fr = e.CSmatrix(:,jj,1); xr = e.CSmatrix(:,jj,2); yr = e.CSmatrix(:,jj,3);  % rel-centre um
        ok = isfinite(xr) & isfinite(yr); if nnz(ok) < minLen, continue; end
        fr = fr(ok); xr = xr(ok); yr = yr(ok);
        [fr,ord] = sort(fr); xr = xr(ord); yr = yr(ord);                              % time order
        inw = fr>=e.winFrames(1) & fr<=e.winFrames(2); if all(isinf(e.winFrames)), inw = true(size(fr)); end
        inCS = inpolygon(xr, yr, rb(:,1), rb(:,2)) & inw;
        uid = sprintf('%s__cs%d_w%d_t%d', char(e.file), e.csID, e.window, e.tracks(jj));
        for r = 1:numel(fr)
            fprintf(fid,'%s,%s,%d,%d,%d,%d,%d,%.6f,%.5f,%.5f,%d\n', ...
                uid, char(e.file), e.cellIndex, e.csID, e.window, e.tracks(jj), ...
                fr(r), fr(r)*dt, xr(r)+cx, yr(r)+cy, inCS(r));
        end
        nTk = nTk + 1; nRow = nRow + numel(fr);
    end
end

% metadata sidecar
mf = fullfile(stepDir,'step_meta.json'); fm = fopen(mf,'w');
if fm >= 0
    fprintf(fm, '{\n  "units": "micrometre, seconds",\n  "n_member_tracks": %d,\n  "n_localizations": %d,\n  "min_len": %d,\n  "columns": "track_uid,file,cellIndex,csID,window,trackCol,frame,t_s,x_um,y_um,inside_cs",\n  "note": "one row per localization; inside_cs=1 => inside the contact-site boundary and time window"\n}\n', ...
        nTk, nRow, minLen);
    fclose(fm);
end
fprintf('cs_step_export: %d member tracks, %d localizations -> %s\n', nTk, nRow, outFile);
end

function v = getf(s,f,d)
if isstruct(s) && isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end

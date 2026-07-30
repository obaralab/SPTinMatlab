function ctl = spt_experiment_panel(parent, opts)
%SPT_EXPERIMENT_PANEL  Shared experiment/condition manager, embeddable in every tool.
%
%   ctl = spt_experiment_panel(parent, opts)
%
% Builds inside PARENT a cell table spanning any number of day/batch folders, with each cell's
% CONDITION, day/replicate, per-stage STATUS (tracked·curated·built·picked·mapped·dwelled, derived
% from the filesystem), the per-stage SPOT AND TRACK COUNTS behind those stages (spots·tracks·filt·
% cur·in build·trk spots — how much survived, not just whether the step ran), QC EXCLUDE flag and
% NOTES. One manifest is the single source of truth — every tool embeds this same panel so
% conditions are defined once and shared.
%
% opts (all optional):
%   .seedFolders  cellstr of folders to scan on open (no dialog needed — for headless/host wiring).
%   .manifestPath auto-load this experiment_manifest.mat on open.
%   .tool         'track'|'curate'|'analyze' (labels only).
%   .actionLabel  text for a host "process selected" button (e.g. 'Build selected'); '' hides it.
%   .actionFcn    @(cells) ... called with the SELECTED cell records when the action button is hit.
%   .onChange     @(manifest) ... called whenever the manifest changes (assign/exclude/scan/load).
%
% ctl (struct of handles): .getCells() .getManifest() .getSelected() .refresh() .load(path)
%   .save(path) .addFolder(path) .panel
%
% The rich cell records + status come from cs_experiment_scan / cs_experiment_status; Compare reads
% getManifest() and calls cs_experiment_aggregate to pool across folders by condition.

if nargin<2 || ~isstruct(opts), opts = struct(); end
actionLabel = getf(opts,'actionLabel','');
actionFcn   = getf(opts,'actionFcn',[]);
onChange    = getf(opts,'onChange',[]);

here = fileparts(mfilename('fullpath'));                 % make cs_experiment_* reachable
d1 = fullfile(fileparts(here),'drivers'); if isfolder(d1), addpath(d1); end

folders = {}; sf = getf(opts,'seedFolders',{}); if ~isempty(sf), folders = cellstr(sf); end   % canonicalised on first scan/add
autoPath = '';   % canonical <project>/experiment_manifest.mat — auto-loaded on open and
                 % auto-saved on every change, so the manifest lives WITH the project and no
                 % one has to remember to save it.
cells = []; rowMap = [];
tbl=[]; eCond=[]; eDay=[]; eFilter=[]; lbl=[];

buildUI();
if ~isempty(folders), doScan(); end
mp = getf(opts,'manifestPath',''); if ~isempty(mp) && isfile(mp), doLoad(mp); end

% NB: getCells must be a NESTED function (reads the LIVE cells) — an anonymous @() cells would capture
% the empty value at build time (the by-value-capture gotcha), so the host would always see 0 cells.
ctl = struct('getCells',@getCellsLive, 'getManifest',@getManifest, 'getSelected',@getSelected, ...
             'refresh',@doScan, 'load',@doLoad, 'save',@doSave, 'addFolder',@addFolder, 'panel',parent, ...
             'setAutoPath',@setAutoPath);

% ======================= nested =======================
    function buildUI()
        delete(allchild(parent));
        g = uigridlayout(parent,[3 1],'RowHeight',{34,30,'1x'},'Padding',[8 8 8 8],'RowSpacing',5);
        r1 = uigridlayout(g,[1 7],'ColumnWidth',{120,84,72,72,150,'1x',0},'Padding',[0 0 0 0],'ColumnSpacing',6);
        uibutton(r1,'Text','➕ Add folder…','FontWeight','bold','BackgroundColor',[0.18 0.45 0.70],'FontColor','w', ...
            'Tooltip','Add a day/batch folder (project root or its analysis/). Its cells appear below.','ButtonPushedFcn',@(s,e) onAdd());
        uibutton(r1,'Text','↻ Rescan','ButtonPushedFcn',@(s,e) doScan(),'Tooltip','Re-scan folders (refresh status), keeping condition/day/exclude/notes.');
        uibutton(r1,'Text','💾 Save','ButtonPushedFcn',@(s,e) onSaveBtn(),'Tooltip','Save the experiment manifest.');
        uibutton(r1,'Text','📂 Load','ButtonPushedFcn',@(s,e) onLoadBtn(),'Tooltip','Load a saved experiment manifest.');
        if ~isempty(actionLabel) && ~isempty(actionFcn)
            uibutton(r1,'Text',actionLabel,'FontWeight','bold','BackgroundColor',[0.40 0.30 0.55],'FontColor','w', ...
                'ButtonPushedFcn',@(s,e) onAction(),'Tooltip','Run this tool''s step on the rows selected in the table.');
        else, uilabel(r1,'Text',''); end
        lbl = uilabel(r1,'Text','Add each day''s folder, then assign conditions. Status is read from the files.','FontColor',[0.2 0.4 0.5]);
        uilabel(r1,'Text','');
        % row 2: assign + filter
        r2 = uigridlayout(g,[1 9],'ColumnWidth',{58,140,64, 52,110,64, 96, 46,'1x'},'Padding',[0 0 0 0],'ColumnSpacing',6);
        uilabel(r2,'Text','condition','HorizontalAlignment','right');
        eCond = uieditfield(r2,'text','Placeholder','e.g. WT');
        uibutton(r2,'Text','Assign','ButtonPushedFcn',@(s,e) onAssign('condition',eCond.Value),'Tooltip','Set the selected rows'' condition.');
        uilabel(r2,'Text','day/rep','HorizontalAlignment','right');
        eDay = uieditfield(r2,'text','Placeholder','e.g. 250408');
        uibutton(r2,'Text','Assign','ButtonPushedFcn',@(s,e) onAssign('day',eDay.Value),'Tooltip','Set the selected rows'' day/replicate label (used as the stats replicate unit).');
        uibutton(r2,'Text','✖ Exclude','ButtonPushedFcn',@(s,e) onToggleExcl(),'Tooltip','Toggle QC-exclude for the selected rows (they drop from analysis but stay recorded).');
        uilabel(r2,'Text','filter','HorizontalAlignment','right');
        eFilter = uieditfield(r2,'text','Placeholder','condition / day / cell / ''unassigned'' / ''unmapped''','ValueChangedFcn',@(s,e) fillTable());
        % row 3: the cell table (the dashboard). The ✓/– lamps say WHICH stages ran; the count block
        % says how much survived each one, so a cell that "tracked" but kept 6 tracks is visible as
        % such instead of looking as healthy as one that kept 800.
        tbl = uitable(g,'ColumnName',{'day','cell','condition','tracked','curated','built','picked','mapped','dwelled', ...
                                     'spots','tracks','filt','cur','in build','trk spots','excl','notes'}, ...
            'ColumnWidth',{110,'auto',110,58,58,44,50,50,56, 62,58,52,52,60,66, 44,'1x'}, ...
            'ColumnEditable',[true false true false false false false false false false false false false false false true true], ...
            'ColumnFormat',[repmat({'char'},1,15) {'logical','char'}], ...
            'SelectionType','row','Multiselect','on','CellEditCallback',@(s,e) onEdit(e), ...
            'Tooltip',['Counts (– = not produced yet):   spots = detections found by Tool 1   ·   ' ...
                       'tracks = tracks it linked   ·   filt = left after Tool 1''s length/displacement filter   ·   ' ...
                       'cur = left after Tool 2''s curation   ·   in build = this cell''s tracks in the active ' ...
                       'TrackStruct   ·   trk spots = localisations in those surviving tracks.']);
    end

    function onAdd()
        d = uigetdir(pwd,'Pick a day/batch folder (project root or its analysis/)');
        if isequal(d,0), return; end
        addFolder(d);
    end
    function addFolder(d)
        d = char(d);
        if ~isfolder(d), return; end
        % Accept an analysis folder whose only build is a NAMED one (Day1_WT.mat) — checking for the
        % literal TrackStruct.mat rejected exactly the projects the naming feature creates.
        hasBuild = false;
        try, hasBuild = ~isempty(cs_active_trackstruct(d)); catch, end
        if ~(hasBuild || isfolder(fullfile(d,'analysis')) || isfolder(fullfile(d,'spt')) || isfolder(fullfile(d,'tracks')))
            setStatus('That folder is not a project/analysis folder (no build, analysis/, spt/ or tracks/).'); return;
        end
        folders = canon_folders([folders(:)' {d}]);
        doScan();
    end

    function F = canon_folders(F)
        % One entry per PROJECT. A project can be named two ways — its root, or its analysis/
        % subfolder — and both were being added: Tool 1 added the root, Tools 2 and 3 added
        % analysis/. Both land in the same <project>/experiment_manifest.mat, so the manifest ended
        % up naming one project twice and every cell was listed twice. Collapse to the root, resolve
        % symlinks and trailing separators, then keep the first of each.
        out = {};
        for i = 1:numel(F)
            d = char(F{i}); if isempty(d), continue; end
            if endsWith(d, filesep), d = d(1:end-1); end
            [par, leaf] = fileparts(d);
            if strcmpi(leaf,'analysis') && ~isempty(par) && isfolder(par), d = par; end   % analysis/ -> its project
            try, r = char(java.io.File(d).getCanonicalPath()); if ~isempty(r), d = r; end, catch, end
            if ~any(strcmp(out, d)), out{end+1} = d; end %#ok<AGROW>
        end
        F = out;
    end

    function doScan()
        if isempty(folders), setStatus('Add a folder first (➕ Add folder…).'); fillTable(); return; end
        prev = cells;
        try, fresh = cs_experiment_scan(folders); catch ME, setStatus(['Scan error: ' ME.message]); return; end
        for k = 1:numel(fresh)                                     % carry over manual assignments
            for q = 1:numel(prev)
                if strcmp(prev(q).folder,fresh(k).folder) && strcmp(prev(q).file,fresh(k).file)
                    fresh(k).condition = prev(q).condition; fresh(k).day = prev(q).day;
                    fresh(k).exclude = prev(q).exclude; fresh(k).notes = prev(q).notes; break;
                end
            end
        end
        cells = fresh; fillTable(); notifyChange();
        nMap = 0; nCond = 0; if ~isempty(cells), nMap = nnz([cells.hasCSW]); nCond = numel(setdiff(unique({cells.condition}),{''})); end
        setStatus(sprintf('%d cell(s) · %d folder(s) · %d mapped · %d condition(s)%s.', ...
            numel(cells), numel(folders), nMap, nCond, totalsTag(cells)));
    end

    function fillTable()
        if isempty(cells), tbl.Data = {}; rowMap = []; return; end
        keep = filterRows();
        rowMap = keep;
        D = cell(numel(keep),17);
        for i = 1:numel(keep)
            c = cells(keep(i)); s = c.status;
            D(i,:) = {c.day, c.file, c.condition, y(s.tracked), y(s.curated), y(s.built), y(s.picked), y(s.mapped), y(s.dwelled), ...
                n(gs(s,'nSpotsRaw')), n(gs(s,'nTracksRaw')), n(gs(s,'nTracksFiltered')), n(gs(s,'nTracksCurated')), ...
                n(gs(s,'nTracksBuilt')), n(spotsAtEnd(s)), logical(c.exclude), c.notes};
        end
        tbl.Data = D;
    end

    function keep = filterRows()
        keep = 1:numel(cells);
        q = ''; if ~isempty(eFilter) && isgraphics(eFilter), q = lower(strtrim(eFilter.Value)); end
        if isempty(q), return; end
        hit = false(1,numel(cells));
        for i = 1:numel(cells)
            c = cells(i); s = c.status;
            kw = strjoin({c.day, c.file, c.condition, ...
                stagesTrue(s), tern(c.exclude,'excluded',''), tern(isempty(c.condition),'unassigned',''), ...
                tern(~s.mapped,'unmapped',''), tern(~s.dwelled,'undwelled','')}, ' ');
            hit(i) = contains(lower(kw), q);
        end
        keep = find(hit);
    end

    function onEdit(e)
        try, r = e.Indices(1); c = e.Indices(2); catch, return; end
        if isempty(rowMap) || r<1 || r>numel(rowMap), return; end
        idx = rowMap(r);
        switch c
            case 1,  cells(idx).day = strtrim(char(string(e.NewData)));
            case 3,  cells(idx).condition = strtrim(char(string(e.NewData)));
            case 16, cells(idx).exclude = logical(e.NewData);
            case 17, cells(idx).notes = char(string(e.NewData));
        end
        notifyChange();
    end

    function onAssign(field, val)
        val = strtrim(char(val)); sel = selRows();
        if isempty(sel), setStatus('Select one or more rows first.'); return; end
        if isempty(val), setStatus(['Type a ' field ' on the left, then Assign.']); return; end
        for r = sel, cells(r).(field) = val; end
        fillTable(); notifyChange();
        setStatus(sprintf('Assigned %s "%s" to %d cell(s).', field, val, numel(sel)));
    end

    function onToggleExcl()
        sel = selRows(); if isempty(sel), setStatus('Select rows to exclude/restore.'); return; end
        for r = sel, cells(r).exclude = ~logical(cells(r).exclude); end
        fillTable(); notifyChange();
        setStatus(sprintf('Toggled exclude on %d cell(s).', numel(sel)));
    end

    function onAction()
        if isempty(actionFcn), return; end
        s = getSelected(); if isempty(s), setStatus('Select rows to process.'); return; end
        try, actionFcn(s); catch ME, setStatus(['Action failed: ' ME.message]); end
        doScan();                                                  % refresh status after the tool ran
    end

    function s = selRows()
        s = []; if isempty(tbl)||~isgraphics(tbl)||isempty(tbl.Selection)||isempty(rowMap), return; end
        rr = tbl.Selection(:)'; rr = rr(rr>=1 & rr<=numel(rowMap)); s = rowMap(rr);
    end
    function c = getCellsLive(), c = cells; end
    function s = getSelected(), r = selRows(); if isempty(r), s = cells([]); else, s = cells(r); end, end
    function m = getManifest(), m = struct('folders',{folders},'cells',cells); end

    function onSaveBtn()
        if isempty(cells), setStatus('Nothing to save.'); return; end
        [fn,fp] = uiputfile({'*.mat','Experiment manifest'},'Save experiment manifest','experiment_manifest.mat');
        if isequal(fn,0), return; end
        doSave(fullfile(fp,fn));
    end
    function doSave(p)
        manifest = getManifest(); %#ok<NASGU>
        try, save(p,'manifest','-v7.3'); setStatus(['Saved ' p]); catch ME, setStatus(['Save failed: ' ME.message]); end
    end
    function onLoadBtn()
        [fn,fp] = uigetfile({'*.mat','Experiment manifest'},'Load experiment manifest');
        if isequal(fn,0), return; end
        doLoad(fullfile(fp,fn));
    end
    function doLoad(p)
        try, L = load(p); catch ME, setStatus(['Load failed: ' ME.message]); return; end
        if ~isfield(L,'manifest') || ~isfield(L.manifest,'cells'), setStatus('Not an experiment manifest.'); return; end
        folders = L.manifest.folders; if ischar(folders), folders = cellstr(folders); end
        % Repair a manifest already carrying the same project under two names — every one written
        % before this fix does, because Tool 1 stored the project root and Tools 2/3 stored analysis/.
        folders = canon_folders(folders);
        cells = L.manifest.cells;
        doScan();                                                 % refresh status, keep loaded conditions
        setStatus(['Loaded ' p]);
    end

    function notifyChange()
        autoSave();                       % keep the project's own manifest current
        if ~isempty(onChange), try, onChange(getManifest()); catch, end, end
    end

    function autoSave()
        if isempty(autoPath) || isempty(cells), return; end
        manifest = getManifest(); %#ok<NASGU>
        try, save(autoPath,'manifest','-v7.3'); catch, end   % silent: this is a background save
    end

    function setAutoPath(p)
        % Point the panel at a project's canonical manifest: load it if it is there, and from now
        % on save every change straight back to it.
        autoPath = char(p);
        if ~isempty(autoPath) && isfile(autoPath), doLoad(autoPath); end
    end
    function setStatus(t), if ~isempty(lbl)&&isgraphics(lbl), lbl.Text = t; end, end
end

% ---- file-scope helpers ----
function s = y(b), if b, s='✓'; else, s='–'; end, end

function s = n(v)
% A count for the table: '–' when the source file that would report it does not exist yet.
if isempty(v) || ~isnumeric(v) || ~isfinite(v), s = '–'; else, s = sprintf('%d', round(v)); end
end

function v = gs(st, f)
% Status counts are additive — a manifest saved before they existed has none, so read defensively.
if isstruct(st) && isfield(st,f), v = st.(f); else, v = NaN; end
end

function t = totalsTag(cells)
% Pooled attrition across every scanned cell, for the summary line: how many detections and tracks
% the whole manifest starts from and how many are still standing. '' when nothing is countable yet.
t = '';
if isempty(cells) || ~isfield(cells,'status'), return; end
st = [cells.status];
raw = tot(st,'nSpotsRaw'); trk = tot(st,'nTracksRaw'); fin = tot(st,'nTracksCurated');
if isnan(fin), fin = tot(st,'nTracksFiltered'); end
if isnan(raw) && isnan(trk), return; end
t = sprintf(' · %s spots · %s tracks linked', n(raw), n(trk));
if ~isnan(fin), t = [t sprintf(' → %s kept', n(fin))]; end
end

function s = tot(st, f)
% Sum one count across cells, ignoring the cells that have no value for it. NaN when none do.
if ~isfield(st,f), s = NaN; return; end
v = [st.(f)]; v = v(isfinite(v));
if isempty(v), s = NaN; else, s = sum(v); end
end

function v = spotsAtEnd(st)
% Detections belonging to the tracks that SURVIVED: from the build when there is one (the build's
% own per-track lengths), otherwise from the KEEP rows of _track_metrics.csv, otherwise from the
% whole metrics pool. This is the only spot count after the raw stage that is cheap to obtain.
v = gs(st,'nSpotsBuilt');
if ~isfinite(v), v = gs(st,'nSpotsKept'); end
if ~isfinite(v), v = gs(st,'nSpotsInTracks'); end
end
function s = stagesTrue(st)
nm = {}; f = {'tracked','curated','built','picked','mapped','dwelled'};
for i=1:numel(f), if st.(f{i}), nm{end+1}=f{i}; end, end %#ok<AGROW>
s = strjoin(nm,' ');
end
function v = getf(s,f,d), if isstruct(s)&&isfield(s,f)&&~isempty(s.(f)), v=s.(f); else, v=d; end, end

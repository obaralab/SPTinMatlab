function ctl = spt_experiment_panel(parent, opts)
%SPT_EXPERIMENT_PANEL  Shared experiment/condition manager, embeddable in every tool.
%
%   ctl = spt_experiment_panel(parent, opts)
%
% Builds inside PARENT a cell table spanning any number of day/batch folders, with each cell's
% CONDITION, day/replicate, its own CALIBRATION (µm/px · dt · where each came from), per-stage
% STATUS (tracked·curated·built·picked·mapped·dwelled, derived from the filesystem), the per-stage
% SPOT AND TRACK COUNTS behind those stages (spots·tracks·filt·cur·in build·trk spots — how much
% survived, not just whether the step ran), QC EXCLUDE flag and NOTES. One manifest is the single
% source of truth — every tool embeds this same panel so conditions are defined once and shared.
%
% CALIBRATION IS PER CELL. Cells in one comparison are routinely acquired on different rigs at
% different frame rates, so one number applied to all of them mis-scales every µm coordinate and
% every diffusion coefficient for the cells it does not describe. Each row resolves its own values
% (cs_experiment_scan -> spt_project_calib), shows WHERE they came from, and can be typed over. A
% typed value is LOCKED and a later Rescan will not touch it; an unresolved one shows '–' rather
% than a plausible-looking default.
%
% opts (all optional):
%   .seedFolders  cellstr of folders to scan on open (no dialog needed — for headless/host wiring).
%   .manifestPath auto-load this experiment_details.mat on open.
%   .tool         'track'|'curate'|'analyze' (labels only).
%   .actionLabel  text for a host "process selected" button (e.g. 'Build selected'); '' hides it.
%   .actionFcn    @(cells) ... called with the SELECTED cell records when the action button is hit.
%   .onChange     @(manifest) ... called whenever the manifest changes (assign/exclude/scan/load).
%
% ctl (struct of handles): .getCells() .getManifest() .getSelected() .refresh() .load(path)
%   .save(path) .addFolder(path) .panel .setAutoPath(projectDir)
%   .setCalib(project, file, pixUm, dtS, src, lock)  one cell's calibration, for a host tool that
%        resolved or was handed a value. lock=false NEVER overwrites a hand-edited row.
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
autoPath = '';   % canonical <project>/experiment_details.mat — auto-loaded on open and
                 % auto-saved on every change, so the manifest lives WITH the project and no
                 % one has to remember to save it.
cells = []; rowMap = [];
tbl=[]; eCond=[]; eDay=[]; eFilter=[]; lbl=[]; eCalPx=[]; eCalDt=[]; bCalAll=[];

buildUI();
if ~isempty(folders), doScan(); end
mp = getf(opts,'manifestPath',''); if ~isempty(mp) && isfile(mp), doLoad(mp); end

% NB: getCells must be a NESTED function (reads the LIVE cells) — an anonymous @() cells would capture
% the empty value at build time (the by-value-capture gotcha), so the host would always see 0 cells.
ctl = struct('getCells',@getCellsLive, 'getManifest',@getManifest, 'getSelected',@getSelected, ...
             'refresh',@doScan, 'load',@doLoad, 'save',@doSave, 'addFolder',@addFolder, 'panel',parent, ...
             'setAutoPath',@setAutoPath, 'setCalib',@setCalib, 'applyCalibTo',@applyCalibTo, ...
             'shownRows',@shownRowsLive);

% ======================= nested =======================
    function buildUI()
        delete(allchild(parent));
        g = uigridlayout(parent,[4 1],'RowHeight',{34,30,30,'1x'},'Padding',[8 8 8 8],'RowSpacing',5);
        r1 = uigridlayout(g,[1 7],'ColumnWidth',{120,84,72,72,150,'1x',0},'Padding',[0 0 0 0],'ColumnSpacing',6);
        uibutton(r1,'Text','➕ Add folder…','FontWeight','bold','BackgroundColor',[0.18 0.45 0.70],'FontColor','w', ...
            'Tooltip','Add a day/batch folder (project root or its analysis/). Its cells appear below.','ButtonPushedFcn',@(s,e) onAdd());
        uibutton(r1,'Text','↻ Rescan','ButtonPushedFcn',@(s,e) doScan(),'Tooltip','Re-scan folders (refresh status), keeping condition/day/exclude/notes.');
        uibutton(r1,'Text','💾 Save','ButtonPushedFcn',@(s,e) onSaveBtn(),'Tooltip','Save the experiment details.');
        uibutton(r1,'Text','📂 Load','ButtonPushedFcn',@(s,e) onLoadBtn(),'Tooltip','Load saved experiment details.');
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
        % row 3: calibration in bulk. Typing into the table sets ONE cell, which is right for a
        % correction and hopeless for a plate: 93 cells whose movies carry no metadata is 93
        % identical edits. The two buttons are deliberately separate rather than one button that
        % infers its scope from whether anything is selected — an empty selection silently meaning
        % "all 93" is the wrong way for that guess to go.
        r3 = uigridlayout(g,[1 8],'ColumnWidth',{64,80, 46,80, 118,150, 10,'1x'}, ...
            'Padding',[0 0 0 0],'ColumnSpacing',6);
        uilabel(r3,'Text','µm/px','HorizontalAlignment','right');
        eCalPx = uieditfield(r3,'numeric','Value',0,'ValueDisplayFormat','%.5g','Limits',[0 5], ...
            'Tooltip',['Pixel size to apply in bulk. LEAVE AT 0 to leave the pixel size alone — so ' ...
                       'you can set dt across a plate without touching a pixel size that was ' ...
                       'measured correctly.']);
        uilabel(r3,'Text','dt (s)','HorizontalAlignment','right');
        eCalDt = uieditfield(r3,'numeric','Value',0,'ValueDisplayFormat','%.5g','Limits',[0 3600], ...
            'Tooltip','Frame interval to apply in bulk. Leave at 0 to leave dt alone.');
        uibutton(r3,'Text','Apply to selected','ButtonPushedFcn',@(s,e) onCalBulk(false), ...
            'Tooltip','Set the calibration of the rows selected in the table below.');
        bCalAll = uibutton(r3,'Text','Apply to all shown','FontWeight','bold', ...
            'ButtonPushedFcn',@(s,e) onCalBulk(true), ...
            'Tooltip',['Set the calibration of every row the table is currently showing. The FILTER ' ...
                       'scopes this: filter to a day or a condition and only those cells are ' ...
                       'touched. You are asked to confirm when this would override a value that was ' ...
                       'measured from a cell''s own files.']);
        uilabel(r3,'Text','');
        uilabel(r3,'Text','Applied values count as hand-typed: they outrank the files and survive a Rescan.', ...
            'FontColor',[0.45 0.45 0.5]);

        % row 4: the cell table (the dashboard). The ✓/– lamps say WHICH stages ran; the count block
        % says how much survived each one, so a cell that "tracked" but kept 6 tracks is visible as
        % such instead of looking as healthy as one that kept 800.
        % µm/px · dt · calib sit right after condition, where a person looks for this cell's own
        % metadata. The two numbers are EDITABLE and the source is not: 'calib' reports what the
        % files said, so it is a readout, and typing in a number is what changes it (to 'edited').
        % ColumnFormat for all three is 'char', deliberately, not 'numeric': a cell that could
        % resolve nothing must render '–' the way every absent count already does, and 'numeric'
        % would force a 0 — a number that looks like a measurement and is not.
        tbl = uitable(g,'ColumnName',{'day','cell','condition','µm/px','dt (s)','calib', ...
                                     'tracked','curated','built','picked','mapped','dwelled', ...
                                     'spots','tracks','filt','cur','in build','trk spots','excl','notes'}, ...
            'ColumnWidth',{110,'auto',110, 72,78,96, 58,58,44,50,50,56, 62,58,52,52,60,66, 44,'1x'}, ...
            'ColumnEditable',[true false true true true false false false false false false false ...
                              false false false false false false true true], ...
            'ColumnFormat',[repmat({'char'},1,18) {'logical','char'}], ...
            'SelectionType','row','Multiselect','on','CellEditCallback',@(s,e) onEdit(e), ...
            'Tooltip',['Calibration is PER CELL: µm/px and dt (s) are this cell''s own, resolved from ' ...
                       'its _settings.txt / TIFF metadata / tracks XML, and ''calib'' says which. ' ...
                       'Type over either one to correct it — a typed value reads "edited" and Rescan ' ...
                       'will not overwrite it. "panel ⚠" means nothing in that cell supplied a value ' ...
                       'and the tool''s fallback was used, so that cell is on a different scale from ' ...
                       'its own data.   Counts (– = not produced yet):   spots = detections found by ' ...
                       'Tool 1   ·   tracks = tracks it linked   ·   filt = left after Tool 1''s ' ...
                       'length/displacement filter   ·   cur = left after Tool 2''s curation   ·   ' ...
                       'in build = this cell''s tracks in the active TrackStruct   ·   trk spots = ' ...
                       'localisations in those surviving tracks.']);
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
        % analysis/. Both land in the same <project>/experiment_details.mat, so the manifest ended
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
        prev = normalizeCells(cells);
        try, fresh = cs_experiment_scan(folders); catch ME, setStatus(['Scan error: ' ME.message]); return; end
        for k = 1:numel(fresh)                                     % carry over manual assignments
            for q = 1:numel(prev)
                if strcmp(prev(q).folder,fresh(k).folder) && strcmp(prev(q).file,fresh(k).file)
                    fresh(k).condition = prev(q).condition; fresh(k).day = prev(q).day;
                    fresh(k).exclude = prev(q).exclude; fresh(k).notes = prev(q).notes;
                    % A HAND-EDITED calibration is the user's correction and outranks anything the
                    % filesystem now says — a rescan silently replacing it would put that cell back
                    % on the wrong scale with no sign that it happened. An UNLOCKED value is
                    % refreshed on purpose: that is what Rescan is for, and a cell tracked since the
                    % last scan now resolves 'settings' where it used to say 'missing'.
                    if prev(q).pixLock
                        fresh(k).pixUm = prev(q).pixUm; fresh(k).pixSrc = 'edited'; fresh(k).pixLock = true;
                    end
                    if prev(q).dtLock
                        fresh(k).dtS = prev(q).dtS; fresh(k).dtSrc = 'edited'; fresh(k).dtLock = true;
                    end
                    break;
                end
            end
        end
        cells = fresh; fillTable(); notifyChange();
        nMap = 0; nCond = 0; if ~isempty(cells), nMap = nnz([cells.hasCSW]); nCond = numel(setdiff(unique({cells.condition}),{''})); end
        setStatus(sprintf('%d cell(s) · %d folder(s) · %d mapped · %d condition(s)%s.', ...
            numel(cells), numel(folders), nMap, nCond, totalsTag(cells)));
    end

    function fillTable()
        if isempty(cells), tbl.Data = {}; rowMap = []; setBulkCount(0); return; end
        keep = filterRows();
        rowMap = keep;
        % Name the count on the button. "Apply to all shown" is honest but says nothing about how
        % many that is, and the filter changes it — a button that reads "(12)" when you expected 93
        % is the cheapest possible way to notice you are still filtered.
        setBulkCount(numel(keep));
        D = cell(numel(keep),20);
        for i = 1:numel(keep)
            c = cells(keep(i)); s = c.status;
            D(i,:) = {c.day, c.file, c.condition, calStr(gf(c,'pixUm')), calStr(gf(c,'dtS')), srcTag(c), ...
                y(s.tracked), y(s.curated), y(s.built), y(s.picked), y(s.mapped), y(s.dwelled), ...
                n(gs(s,'nSpotsRaw')), n(gs(s,'nTracksRaw')), n(gs(s,'nTracksFiltered')), n(gs(s,'nTracksCurated')), ...
                n(gs(s,'nTracksBuilt')), n(spotsAtEnd(s)), logical(c.exclude), c.notes};
        end
        tbl.Data = D;
    end

    function keep = filterRows()
        % NB: these once called a helper named tern() that this file never defined, so EVERY
        % keystroke in the filter box threw and the box did nothing. It went unnoticed because
        % nothing else calls filterRows with a non-empty query — fillTable's own path returns early.
        % Found by spt_calib_bulk_smoke, which filters in order to test bulk scoping.
        keep = 1:numel(cells);
        q = ''; if ~isempty(eFilter) && isgraphics(eFilter), q = lower(strtrim(eFilter.Value)); end
        if isempty(q), return; end
        hit = false(1,numel(cells));
        for i = 1:numel(cells)
            c = cells(i); s = c.status;
            kw = strjoin({c.day, c.file, c.condition, ...
                stagesTrue(s), tern_(c.exclude,'excluded',''), tern_(isempty(c.condition),'unassigned',''), ...
                tern_(~s.mapped,'unmapped',''), tern_(~s.dwelled,'undwelled','')}, ' ');
            hit(i) = contains(lower(kw), q);
        end
        keep = find(hit);
    end

    function onEdit(e)
        try, r = e.Indices(1); c = e.Indices(2); catch, return; end
        if isempty(rowMap) || r<1 || r>numel(rowMap), return; end
        if c < 1 || c > numel(tbl.ColumnName), return; end
        idx = rowMap(r);
        % Dispatch on the column NAME, not its index. These indices have already shifted once, when
        % the calibration columns went in after `condition`, and a switch on numbers gives no sign
        % when they shift again — it just starts writing the typed value into a different field.
        switch char(tbl.ColumnName{c})
            case 'day',       cells(idx).day = strtrim(char(string(e.NewData)));
            case 'condition', cells(idx).condition = strtrim(char(string(e.NewData)));
            case 'excl',      cells(idx).exclude = logical(e.NewData);
            case 'notes',     cells(idx).notes = char(string(e.NewData));
            case 'µm/px'
                % The bounds are spt_project_calib's own (its inr() gate) and Tool 1's edit-field
                % Limits. One set of numbers in three places: a value this rejects must be one the
                % resolver would refuse too, or the manifest could hold a calibration no tool trusts.
                v = str2double(strtrim(char(string(e.NewData))));
                if isfinite(v) && v >= 0.005 && v <= 5
                    cells(idx).pixUm = v; cells(idx).pixSrc = 'edited'; cells(idx).pixLock = true;
                else
                    setStatus('Pixel size must be 0.005–5 µm/px — value not changed.');
                end
                fillTable();
            case 'dt (s)'
                v = str2double(strtrim(char(string(e.NewData))));
                if isfinite(v) && v >= 1e-6 && v <= 3600
                    cells(idx).dtS = v; cells(idx).dtSrc = 'edited'; cells(idx).dtLock = true;
                else
                    setStatus('Frame interval must be 1e-6–3600 s — value not changed.');
                end
                fillTable();
        end
        notifyChange();
    end

    function onCalBulk(allShown)
        % Bulk calibration. Scope is EXPLICIT — the selected rows, or every row the filter is
        % currently showing — never inferred from an empty selection.
        px = 0; dt = 0;
        if ~isempty(eCalPx) && isgraphics(eCalPx), px = eCalPx.Value; end
        if ~isempty(eCalDt) && isgraphics(eCalDt), dt = eCalDt.Value; end
        doPx = px >= 0.005 && px <= 5;          % same gate as onEdit and spt_project_calib's inr()
        doDt = dt >= 1e-6  && dt <= 3600;
        if ~doPx && ~doDt
            setStatus('Type a µm/px (0.005–5) or a dt (1e-6–3600) first — 0 means "leave this one alone".');
            return
        end
        if allShown, idxs = rowMap(:)'; else, idxs = selRows(); end
        if isempty(idxs)
            setStatus(tern_(allShown, 'No rows are shown — add a folder first.', ...
                                      'Select one or more rows in the table first.'));
            return
        end
        % Confirm only when this DESTROYS information: a value that was measured from a cell's own
        % files is evidence, and overwriting it in bulk is the one outcome nobody would want by
        % accident. Overwriting a 'missing' or an earlier hand edit is not that, and prompting for
        % those would train the prompt to be clicked through.
        nMeas = numel(measuredAmong(idxs, doPx, doDt));
        if nMeas > 0
            f = ancestor(tbl,'figure');
            msg = sprintf(['%d of these %d cells have a calibration read from their own files. ' ...
                'Applying will override those measurements with your typed value.'], nMeas, numel(idxs));
            if ~isempty(f) && isgraphics(f)
                ans_ = uiconfirm(f, msg, 'Override measured calibration?', ...
                    'Options',{'Apply anyway','Cancel'}, 'DefaultOption',2, 'CancelOption',2, 'Icon','warning');
                if ~strcmp(ans_,'Apply anyway'), setStatus('Bulk calibration cancelled — nothing changed.'); return; end
            end
        end
        applyCalibTo(idxs, tern_(doPx,px,NaN), tern_(doDt,dt,NaN));
        setStatus(sprintf('Applied %s to %d cell(s)%s. These now read "edited" and outrank the files.', ...
            strjoin([repmat({sprintf('%.5g µm/px',px)},1,doPx), repmat({sprintf('%.5g s',dt)},1,doDt)], ' + '), ...
            numel(idxs), tern_(nMeas>0, sprintf(' (%d measured value(s) overridden)', nMeas), '')));
    end

    function idxs = measuredAmong(idxs, doPx, doDt)
        % Those of these cells whose value for a field being SET came from a file rather than from a
        % person or from nowhere.
        keep = false(1,numel(idxs));
        for k = 1:numel(idxs)
            c = cells(idxs(k));
            if doPx && ~gLock(c,'pixLock') && isMeasured(gStr(c,'pixSrc')), keep(k) = true; end
            if doDt && ~gLock(c,'dtLock')  && isMeasured(gStr(c,'dtSrc')),  keep(k) = true; end
        end
        idxs = idxs(keep);
    end

    function applyCalibTo(idxs, pixUm, dtS)
        % The bulk write itself, exposed on ctl so it can be driven headlessly — the confirmation
        % above is chrome, this is the part that must be right. NaN means "leave that field alone",
        % which is what lets dt be set across a plate without disturbing a good pixel size.
        cells = normalizeCells(cells);
        idxs = idxs(idxs >= 1 & idxs <= numel(cells));
        if isempty(idxs), return; end
        for k = idxs
            if isfinite(pixUm)
                cells(k).pixUm = pixUm; cells(k).pixSrc = 'edited'; cells(k).pixLock = true;
            end
            if isfinite(dtS)
                cells(k).dtS = dtS; cells(k).dtSrc = 'edited'; cells(k).dtLock = true;
            end
        end
        % ONE notify for the whole batch, not one per cell: notifyChange saves the manifest and
        % re-resolves the host tool's calibration, and doing that 93 times would write the file 93
        % times for a single user action.
        fillTable(); notifyChange();
    end

    function setCalib(project, file, pixUm, dtS, src, lock)
        % One cell's calibration, set by a host tool (Tool 1 stamps back what its run actually
        % resolved, so the manifest shows the scale each cell was tracked on). lock=false is a
        % REPORT and must never overwrite a correction the user typed — that is the same rule
        % doScan applies, enforced here so no caller can route around it.
        if nargin < 6, lock = false; end
        if nargin < 5 || isempty(src), src = 'missing'; end
        cells = normalizeCells(cells);
        idx = findCell(project, file); if isempty(idx), return; end
        changed = false;
        if ~(cells(idx).pixLock && ~lock) && isfinite(pixUm)
            if ~isequaln(cells(idx).pixUm,pixUm) || ~strcmp(cells(idx).pixSrc,src), changed = true; end
            cells(idx).pixUm = pixUm; cells(idx).pixSrc = src; cells(idx).pixLock = lock || cells(idx).pixLock;
        end
        if ~(cells(idx).dtLock && ~lock) && isfinite(dtS)
            if ~isequaln(cells(idx).dtS,dtS) || ~strcmp(cells(idx).dtSrc,src), changed = true; end
            cells(idx).dtS = dtS; cells(idx).dtSrc = src; cells(idx).dtLock = lock || cells(idx).dtLock;
        end
        if ~changed, return; end            % a batch re-stamping the same numbers must not re-save per cell
        fillTable(); notifyChange();
    end

    function idx = findCell(project, file)
        % (project, cell) is the manifest key. When a project is NAMED the match is scoped to it and
        % never widens: falling back to the base name bound one project's calibration edit to another
        % project's identically-named cell, and Day1/Cell1 + Day2/Cell1 is this pipeline's own
        % layout. The base-name path survives only for a caller that genuinely does not know the
        % project, and only when the name is unambiguous.
        idx = [];
        if isempty(cells), return; end
        hit = strcmp({cells.file}, char(file)); if ~any(hit), return; end
        p = char(project);
        if ~isempty(p)
            try, r = char(java.io.File(p).getCanonicalPath()); if ~isempty(r), p = r; end, catch, end
            same = hit & strcmp({cells.project}, p);
            if any(same), idx = find(same,1); end
            return
        end
        if nnz(hit) == 1, idx = find(hit,1); end
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

    function r = shownRowsLive()
        % NESTED, not @() rowMap(:)' — the same by-value-capture gotcha getCells carries a note
        % about. An anonymous handle would capture rowMap as it was when ctl was built (empty, or
        % the unfiltered set) and go on returning that no matter what the filter did.
        r = rowMap(:)';
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
        [fn,fp] = uiputfile({'*.mat','Experiment details'},'Save experiment details','experiment_details.mat');
        if isequal(fn,0), return; end
        doSave(fullfile(fp,fn));
    end
    function doSave(p)
        manifest = getManifest(); %#ok<NASGU>
        try, save(p,'manifest','-v7.3'); setStatus(['Saved ' p]); catch ME, setStatus(['Save failed: ' ME.message]); end
    end
    function onLoadBtn()
        [fn,fp] = uigetfile({'*.mat','Experiment details'},'Load experiment details');
        if isequal(fn,0), return; end
        doLoad(fullfile(fp,fn));
    end
    function doLoad(p)
        try, L = load(p); catch ME, setStatus(['Load failed: ' ME.message]); return; end
        if ~isfield(L,'manifest') || ~isfield(L.manifest,'cells'), setStatus('Not an experiment details file.'); return; end
        folders = L.manifest.folders; if ischar(folders), folders = cellstr(folders); end
        % Repair a manifest already carrying the same project under two names — every one written
        % before this fix does, because Tool 1 stored the project root and Tools 2/3 stored analysis/.
        folders = canon_folders(folders);
        % A manifest written before calibration was per cell has none of the six fields. Fill them in
        % on the way in, so getCells() consumers never have to guess whether a record has them.
        cells = normalizeCells(L.manifest.cells);
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

    function setAutoPath(projectDir)
        % Point the panel at a project's canonical details file: load whatever is there, and from now
        % on save every change straight back to the CANONICAL name. cs_experiment_file resolves both
        % spellings — a project written before the rename still has experiment_manifest.mat, so it is
        % loaded from the old name and the next save writes the new one, migrating it silently.
        % Callers pass the PROJECT FOLDER, not a file, so all three tools cannot drift on the name.
        [autoPath, existing] = cs_experiment_file(projectDir);
        if ~isempty(existing), doLoad(existing); end
    end
    function setBulkCount(n)
        if isempty(bCalAll) || ~isgraphics(bCalAll), return; end
        bCalAll.Text = sprintf('Apply to all shown (%d)', n);
    end

    function setStatus(t), if ~isempty(lbl)&&isgraphics(lbl), lbl.Text = t; end, end
end

% ---- file-scope helpers ----
function s = y(b), if b, s='✓'; else, s='–'; end, end

function tf = isMeasured(src)
% A value that came from a FILE. 'edited' is a person, 'panel' is a fallback, 'missing' is nothing —
% none of those is evidence, so overwriting them destroys nothing and needs no confirmation.
tf = any(strcmp(src, {'settings','movie','xml','derived','image'}));
end

function v = gStr(c, f)
v = ''; if isfield(c,f) && (ischar(c.(f)) || isstring(c.(f))), v = char(c.(f)); end
end

function tf = gLock(c, f)
tf = isfield(c,f) && ~isempty(c.(f)) && logical(c.(f));
end

function y_ = tern_(c,a,b), if c, y_ = a; else, y_ = b; end, end

function c = normalizeCells(c)
% Add the per-cell calibration fields to records that predate them, with the same honest defaults
% cs_experiment_scan uses (NaN, not a plausible number). Written as a loop over MISSING fields only,
% so a record that already has them keeps its values.
if isempty(c) || ~isstruct(c), return; end
def = {'pixUm',NaN,'pixSrc','missing','pixLock',false,'dtS',NaN,'dtSrc','missing','dtLock',false};
for i = 1:2:numel(def)
    if ~isfield(c, def{i}), [c.(def{i})] = deal(def{i+1}); end
end
% ...and repair individual records left empty by an older write, so pixLock is always a usable flag.
for k = 1:numel(c)
    if isempty(c(k).pixLock), c(k).pixLock = false; end
    if isempty(c(k).dtLock),  c(k).dtLock  = false; end
    if isempty(c(k).pixUm),   c(k).pixUm   = NaN;   end
    if isempty(c(k).dtS),     c(k).dtS     = NaN;   end
    if isempty(c(k).pixSrc),  c(k).pixSrc  = 'missing'; end
    if isempty(c(k).dtSrc),   c(k).dtSrc   = 'missing'; end
end
end

function v = gf(c, f)
% One calibration number off a record, defensively — fillTable can run on a manifest loaded before
% these fields existed and before doScan has replaced it.
if isstruct(c) && isfield(c,f) && ~isempty(c.(f)) && isnumeric(c.(f)), v = c.(f); else, v = NaN; end
end

function s = calStr(v)
% A calibration number for the table: '–' when nothing could supply it. Same convention as n() below
% — an absent value must not be shown as a number, because every number here looks like a measurement.
if isempty(v) || ~isnumeric(v) || ~isfinite(v), s = '–'; else, s = sprintf('%.5g', v); end
end

function s = srcTag(c)
% Where this row's two numbers came from. Collapsed to one string because they almost always agree;
% when they do not, both are named (e.g. 'settings/movie') rather than one being picked to stand for
% both. 'panel' carries a ⚠ — it is the one source that is NOT this cell's own data.
p = tagOf(c,'pixSrc'); d = tagOf(c,'dtSrc');
if strcmp(p,d), s = p; else, s = [p '/' d]; end
if strcmp(p,'panel') || strcmp(d,'panel'), s = [s ' ⚠']; end
end

function t = tagOf(c, f)
t = 'missing';
if isstruct(c) && isfield(c,f) && ~isempty(c.(f)) && (ischar(c.(f)) || isstring(c.(f))), t = char(c.(f)); end
end

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

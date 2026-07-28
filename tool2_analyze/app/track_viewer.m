% ============================================================
% track_viewer.m  —  SPT track inspection and filtering
% MATLAB R2019b+
%
% Fixes vs v1:
%   - Folder mode: scan a folder for XML+CSV pairs
%   - Local-density and displacement-variance histogram plots
%   - Y-axis flipped to match ImageJ orientation
%   - Batch filter by percentile of disp variance / local density
%   - Filter histograms update live with threshold lines
%
% Usage: track_viewer()
% ============================================================

function track_viewer(parent, exportDir, overlayFcn, includeFiles, opts)
% track_viewer                    -> opens its own window (standalone, as before)
% track_viewer(container)         -> builds into a uitab / uipanel / uifigure
%                                    (embedded, e.g. the Curate tab of spt_pipeline_app)
% track_viewer(container,exportDir) -> also pre-fills the Export destination so
%                                    curated tracks land where the pipeline reads them
% track_viewer(container,exportDir,overlayFcn) -> overlayFcn(base) returns
%                                    struct('er',erPath,'mito',mitoPath) so each cell's
%                                    ER/mito overlay auto-loads on file load (no manual pick)

S.spots_t        = table();
S.track_metrics  = table();
S.xml_doc        = [];
S.builtin_xml_doc = [];   % TrackMate session XML for builtin export
S.file_list      = {};   % {xml_path, csv_path, base_name, builtin_xml_path}
S.current_file   = 0;
S.frame_interval = 1;
S.loaded         = false;
S.kept_ids       = [];
S.manual_keep    = [];   % tracks the user forced KEEP (survive a filter re-apply)
S.manual_reject  = [];   % tracks the user forced REJECT (survive a filter re-apply)
S.selected_id    = [];
S.shown_ids      = [];
S.current_frame  = 0;
S.playing        = false;
S.play_timer     = [];
S.resample_seed  = 1;
S.filter_log     = {};   % cell array of filter action records
S.er_img         = [];   % ER overlay: whole-movie occupancy/MIP (the spatial overview)
S.mito_img       = [];   % mito overlay: whole-movie occupancy/MIP
S.er_path='';   S.mito_path='';    S.er_nfr=0; S.mito_nfr=0;              % per-frame seg stacks: path + page count
S.er_fg=[];     S.mito_fg=[];      S.er_isMask=false; S.mito_isMask=false; % fg label + whether it's a mask
S.spt_img=[]; S.spt_path=''; S.spt_nfr=0; S.spt_fg=[]; S.spt_isMask=false; S.spt_hi=[];  % raw SPT movie (selected-track background)
S.ovH_sp = [];   % overview overlay image handle (retinted per frame during playback)
S.overlayFcn     = [];   % overlayFcn(base) -> struct('er',path,'mito',path) for auto-load
DENSITY_RADIUS   = 1.0;
if nargin >= 3 && ~isempty(overlayFcn) && isa(overlayFcn,'function_handle'), S.overlayFcn = overlayFcn; end
S.incFiles = {};   % session cell selection: if non-empty, only these cell bases are loaded ({}=all)
if nargin >= 4 && ~isempty(includeFiles) && iscell(includeFiles), S.incFiles = includeFiles; end
% ---- read/export options (5th arg). Defaults reproduce the legacy TrackMate behaviour so the
% original app is unaffected; Tool 2 passes readPrefer='filtered', exportSuffix='curated',
% preserveCloud=true to read Tool 1's curated pair and keep the full localization cloud on export.
S.readPrefer='raw'; S.exportSuffix='filtered'; S.preserveCloud=false;
if nargin >= 5 && ~isempty(opts) && isstruct(opts)
    if isfield(opts,'readPrefer')    && ~isempty(opts.readPrefer),    S.readPrefer    = char(opts.readPrefer);   end
    if isfield(opts,'exportSuffix')  && ~isempty(opts.exportSuffix),  S.exportSuffix  = char(opts.exportSuffix); end
    if isfield(opts,'preserveCloud') && ~isempty(opts.preserveCloud), S.preserveCloud = logical(opts.preserveCloud); end
end

% ---- Host: own window (standalone) or an embedded parent container --------
if nargin < 1 || isempty(parent)
    fig = uifigure('Name','Track Viewer','Position',[30 30 1600 900],...
        'AutoResizeChildren','off','Color',[0.95 0.95 0.95]);
    fig.CloseRequestFcn = @(~,~) on_close();
    container = fig;
    ownFig = true;
else
    container = parent;                 % embed into a uitab / uipanel / uifigure
    fig = ancestor(parent,'figure');    % figure-level handle for any dialogs
    ownFig = false;
    try, parent.DeleteFcn = @(~,~) do_pause(); catch, end  % stop playback timer if the host closes
end

% 3-column top-level grid
gl = uigridlayout(container,[1 3],...
    'ColumnWidth',{300,'1x',340},...
    'Padding',[6 6 6 6],'ColumnSpacing',6,...
    'BackgroundColor',[0.95 0.95 0.95]);

% ============================================================
% LEFT PANEL — controls
% ============================================================
lp = uipanel(gl,'Title','Controls','FontSize',10,'FontWeight','bold');
lp.Layout.Column = 1;
lg = uigridlayout(lp,[60 2],...
    'RowHeight',   repmat({22},1,60),...
    'ColumnWidth', {'fit','1x'},...
    'Scrollable','on',...
    'Padding',[5 4 5 4],'RowSpacing',2,...
    'BackgroundColor',[0.97 0.97 0.97]);

row = 0;

% -- Load section --  (the folder auto-loads from the Experiment tab's tracks folder;
% "Load single file" below stays for loading a one-off XML+CSV outside that flow)
row=row+1; sec_lbl(lg,row,'LOAD (auto from Experiment tracks folder)');
row=row+1; lbl2(lg,row,'Single XML (optional):');
row=row+1; c.xml = wide_txt(lg,row,'');
row=row+1; lbl2(lg,row,'Spots CSV:');
row=row+1; c.csv = wide_txt(lg,row,'');
row=row+1;
c.load_btn = wide_btn(lg,row,'Load single file',[0.3 0.3 0.3],'white');
c.load_btn.ButtonPushedFcn = @(~,~) do_load_single();

row=row+1;
c.status = uilabel(lg,'Text','Not loaded','FontSize',9,...
    'FontColor',[0.4 0.4 0.4],'WordWrap','on');
c.status.Layout.Row = row; c.status.Layout.Column = [1 2];

% -- File navigation (folder mode) --
row=row+1; sec_lbl(lg,row,'FILE');
row=row+1;
c.prev_btn = half_btn(lg,row,1,'< Prev',[0.8 0.8 0.8],[0 0 0]);
c.next_btn = half_btn(lg,row,2,'Next >',[0.8 0.8 0.8],[0 0 0]);
c.prev_btn.ButtonPushedFcn = @(~,~) nav_file(-1);
c.next_btn.ButtonPushedFcn = @(~,~) nav_file(+1);
row=row+1;
c.file_lbl = uilabel(lg,'Text','—','FontSize',8,...
    'FontColor',[0.3 0.3 0.3],'WordWrap','on','HorizontalAlignment','center');
c.file_lbl.Layout.Row = row; c.file_lbl.Layout.Column = [1 2];

% -- Tracking parameters (from YOUR TrackMate run) — drive the crowding metrics --
row=row+1; sec_lbl(lg,row,'TRACKING PARAMETERS (from Tool 1 run)');
row=row+1; lbl2(lg,row,'Linking max dist (µm):');
c.link_dist = uispinner(lg,'Limits',[0.05 20],'Value',1.0,'Step',0.1,'FontSize',9, ...
    'Tooltip',['Frame-to-frame LAP search radius you used. The local-density crowding ' ...
    'metric is measured at THIS radius (so a track counts as crowded when other spots fall ' ...
    'inside the window the linker actually searched). Was hardcoded 1.0.'], ...
    'ValueChangedFcn',@(~,~) on_param_change());
c.link_dist.Layout.Row=row; c.link_dist.Layout.Column=2;
row=row+1; lbl2(lg,row,'Gap-close max dist (µm):');
c.gap_dist = uispinner(lg,'Limits',[0.05 20],'Value',1.0,'Step',0.1,'FontSize',9, ...
    'Tooltip','Gap-closing LAP max distance. A single step longer than this can only be a mis-link (used by the jump filter).', ...
    'ValueChangedFcn',@(~,~) on_param_change());
c.gap_dist.Layout.Row=row; c.gap_dist.Layout.Column=2;
row=row+1; lbl2(lg,row,'Max frame gap:');
c.max_frame_gap = uispinner(lg,'Limits',[0 10],'Value',1,'Step',1,'RoundFractionalValues','on','FontSize',9, ...
    'Tooltip','Max frames a gap may span in your tracking (recorded with the filtered output for provenance).');
c.max_frame_gap.Layout.Row=row; c.max_frame_gap.Layout.Column=2;

% -- Filter section --  (crowding = local density, mis-links = the jump gate; NND removed)
row=row+1; sec_lbl(lg,row,'FILTER — sliders (the actual thresholds)');
row=row+1; c.lbl_dv = lbl2(lg,row,'Max disp var: —');
row=row+1;
c.max_dv = uislider(lg,'Limits',[0 1],'Value',1,...
    'ValueChangedFcn',@(~,~) preview_filter(),'FontSize',8);
c.max_dv.Layout.Row=row; c.max_dv.Layout.Column=[1 2];

row=row+1; c.lbl_dn = lbl2(lg,row,'Max density: —');
row=row+1;
c.max_dn = uislider(lg,'Limits',[0 50],'Value',50,...
    'ValueChangedFcn',@(~,~) preview_filter(),'FontSize',8);
c.max_dn.Layout.Row=row; c.max_dn.Layout.Column=[1 2];

row=row+1;
c.reject_jumps = uicheckbox(lg,'Text','Reject jumps > gap-close dist','Value',false,'FontSize',9, ...
    'Tooltip',['Reject any track with a single step longer than the gap-close distance — a jump ' ...
    'beyond the LAP search window is the classic mis-link signature (density-independent).'], ...
    'ValueChangedFcn',@(~,~) preview_filter());
c.reject_jumps.Layout.Row=row; c.reject_jumps.Layout.Column=[1 2];

row=row+1; sec_lbl(lg,row,'FILTER — percentile (label shows the threshold value)');
row=row+1; c.pctlbl_dv = lbl2(lg,row,'Disp var keep below p:');
c.pct_dv = uispinner(lg,'Limits',[0 100],'Value',100,'Step',5,...
    'FontSize',9,'ValueChangedFcn',@(~,~) apply_percentile_filter());
c.pct_dv.Layout.Row=row; c.pct_dv.Layout.Column=2;
row=row+1; c.pctlbl_dn = lbl2(lg,row,'Density keep below p:');
c.pct_dn = uispinner(lg,'Limits',[0 100],'Value',100,'Step',5,...
    'FontSize',9,'ValueChangedFcn',@(~,~) apply_percentile_filter());
c.pct_dn.Layout.Row=row; c.pct_dn.Layout.Column=2;
row=row+1;
c.filt_lbl = uilabel(lg,'Text','','FontSize',9,'FontColor',[0.1 0.5 0.1],'WordWrap','on');
c.filt_lbl.Layout.Row=row; c.filt_lbl.Layout.Column=[1 2];
row=row+1;
c.apply_btn = wide_btn(lg,row,'Apply filter',[0.16 0.50 0.26],'white');
c.apply_btn.ButtonPushedFcn = @(~,~) do_apply_filter();

% -- Inspect section --
row=row+1; sec_lbl(lg,row,'INSPECT');
row=row+1;
c.kept_chk = uicheckbox(lg,'Text','Kept only','Value',false,...
    'ValueChangedFcn',@(~,~) do_reshuffle(),'FontSize',9);
c.kept_chk.Layout.Row=row; c.kept_chk.Layout.Column=1;
c.max_shown = uispinner(lg,'Limits',[10 2000],'Value',100,'Step',10,...
    'FontSize',9,'ValueChangedFcn',@(~,~) do_reshuffle());
c.max_shown.Layout.Row=row; c.max_shown.Layout.Column=2;
row=row+1;
c.reshuffle = wide_btn(lg,row,'Reshuffle',[0.85 0.85 0.85],[0 0 0]);
c.reshuffle.ButtonPushedFcn = @(~,~) do_reshuffle();
row=row+1;
c.toggle_btn = wide_btn(lg,row,'Toggle keep/reject',[0.85 0.85 0.85],[0 0 0]);
c.toggle_btn.ButtonPushedFcn = @(~,~) do_toggle();
row=row+1;
c.sel_lbl = uilabel(lg,'Text','Click track to select','FontSize',8,...
    'WordWrap','on','FontColor',[0.2 0.2 0.2]);
c.sel_lbl.Layout.Row=row; c.sel_lbl.Layout.Column=[1 2];

% -- Playback --
row=row+1; sec_lbl(lg,row,'PLAYBACK');
row=row+1; lbl2(lg,row,'FPS:');
c.fps = uispinner(lg,'Limits',[1 60],'Value',15,'Step',1,'FontSize',9);
c.fps.Layout.Row=row; c.fps.Layout.Column=2;
row=row+1; lbl2(lg,row,'Emitter r (um):');
c.emitter_rad = uispinner(lg,'Limits',[0.01 2],'Value',0.25,'Step',0.05,...
    'FontSize',9,'ValueChangedFcn',@(~,~) refreshTraj());
c.emitter_rad.Layout.Row=row; c.emitter_rad.Layout.Column=2;
row=row+1; lbl2(lg,row,'Link ring r (um):');
c.nearby_rad = uispinner(lg,'Limits',[0.05 5],'Value',0.5,'Step',0.05,...
    'FontSize',9,'ValueChangedFcn',@(~,~) refreshTraj());
c.nearby_rad.Layout.Row=row; c.nearby_rad.Layout.Column=2;
row=row+1;
c.play_btn  = half_btn(lg,row,1,'Play', [0.18 0.80 0.44],'white');
c.pause_btn = half_btn(lg,row,2,'Pause',[0.91 0.30 0.24],'white');
c.play_btn.ButtonPushedFcn  = @(~,~) do_play();
c.pause_btn.ButtonPushedFcn = @(~,~) do_pause();

% -- Export --
row=row+1; sec_lbl(lg,row,'EXPORT (current file)');
row=row+1; c.export_dir = wide_txt(lg,row,'');
row=row+1;
c.export_btn = wide_btn(lg,row,['Export ' S.exportSuffix],[0.17 0.24 0.31],'white');
c.export_btn.ButtonPushedFcn = @(~,~) do_export();
row=row+1;
c.export_next_btn = wide_btn(lg,row,'Export + Next ▶',[0.15 0.36 0.30],'white');
c.export_next_btn.ButtonPushedFcn = @(~,~) do_export_next();
row=row+1;
c.ws_btn = wide_btn(lg,row,'Send data to workspace',[0.40 0.20 0.60],'white');
c.ws_btn.ButtonPushedFcn = @(~,~) send_to_workspace();

% -- Structure overlay (ER / mito) --
row=row+1; sec_lbl(lg,row,'OVERLAY (ER / mito structure)');
row=row+1; lbl2(lg,row,'Overlay FOV (um):');
c.ov_fov = uispinner(lg,'Limits',[1 500],'Value',27.61,'Step',0.5,'FontSize',9,...
    'ValueChangedFcn',@(~,~) update_spatial());   % physical extent the structure image spans (match the track FOV)
c.ov_fov.Layout.Row=row; c.ov_fov.Layout.Column=2;
row=row+1;
c.er_btn   = half_btn(lg,row,1,'Pick ER',  [0.16 0.55 0.45],'white');
c.mito_btn = half_btn(lg,row,2,'Pick mito',[0.75 0.45 0.15],'white');
c.er_btn.ButtonPushedFcn   = @(~,~) pick_overlay('er');
c.mito_btn.ButtonPushedFcn = @(~,~) pick_overlay('mito');
row=row+1;
c.er_chk   = uicheckbox(lg,'Text','Show ER','Value',true,...
    'ValueChangedFcn',@(~,~) update_spatial(),'FontSize',9);
c.er_chk.Layout.Row=row; c.er_chk.Layout.Column=1;
c.mito_chk = uicheckbox(lg,'Text','Show mito','Value',true,...
    'ValueChangedFcn',@(~,~) update_spatial(),'FontSize',9);
c.mito_chk.Layout.Row=row; c.mito_chk.Layout.Column=2;
% -- raw SPT movie as the selected-track background (zoomed to the track, plays per frame) --
row=row+1;
c.spt_chk = uicheckbox(lg,'Text','Raw SPT bg','Value',true,'FontSize',9, ...
    'Tooltip','Show the raw SPT movie behind the selected track (zoomed, plays per frame). Only the selected + nearby spots are ringed on top.', ...
    'ValueChangedFcn',@(~,~) refreshTraj());
c.spt_chk.Layout.Row=row; c.spt_chk.Layout.Column=1;
c.spt_con = uispinner(lg,'Limits',[0.05 1],'Value',0.5,'Step',0.05,'FontSize',9, ...
    'Tooltip','Raw-image contrast: brightness saturates at contrast·(robust max). Lower = brighter.', ...
    'ValueChangedFcn',@(~,~) refreshTraj());
c.spt_con.Layout.Row=row; c.spt_con.Layout.Column=2;
% -- colour choices (overlay + tracks) --
COL_ITEMS = {'green','magenta','cyan','blue','red','orange','yellow','purple','grey','black'};
row=row+1; lbl2(lg,row,'ER colour:');
c.col_er = uidropdown(lg,'Items',COL_ITEMS,'Value','green','FontSize',9,'ValueChangedFcn',@(~,~) on_color_change());
c.col_er.Layout.Row=row; c.col_er.Layout.Column=2;
row=row+1; lbl2(lg,row,'Mito colour:');
c.col_mito = uidropdown(lg,'Items',COL_ITEMS,'Value','magenta','FontSize',9,'ValueChangedFcn',@(~,~) on_color_change());
c.col_mito.Layout.Row=row; c.col_mito.Layout.Column=2;
row=row+1; lbl2(lg,row,'Kept colour:');
c.col_kept = uidropdown(lg,'Items',COL_ITEMS,'Value','blue','FontSize',9,'ValueChangedFcn',@(~,~) on_color_change());
c.col_kept.Layout.Row=row; c.col_kept.Layout.Column=2;
row=row+1; lbl2(lg,row,'Excluded colour:');
c.col_excl = uidropdown(lg,'Items',COL_ITEMS,'Value','red','FontSize',9,'ValueChangedFcn',@(~,~) on_color_change());
c.col_excl.Layout.Row=row; c.col_excl.Layout.Column=2;
row=row+1;
c.ov_lbl = uilabel(lg,'Text','Pick ER / mito images to overlay (colours set above)',...
    'FontSize',8,'WordWrap','on','FontColor',[0.3 0.3 0.3]);
c.ov_lbl.Layout.Row=row; c.ov_lbl.Layout.Column=[1 2];

% -- Batch filter --
row=row+1; sec_lbl(lg,row,'BATCH FILTER (all files · same thresholds as above)');
row=row+1;
c.batch_note = uilabel(lg,'Text',['Batch applies the EXACT thresholds you set above to every ' ...
    'file: Max disp var, Max density, and the jump gate. Tune on one representative cell, ' ...
    'then run — what you see here is what every file gets.'],...
    'FontSize',8,'WordWrap','on','FontColor',[0.3 0.3 0.3]);
c.batch_note.Layout.Row=row; c.batch_note.Layout.Column=[1 2];
row=row+1;
c.batch_preview = uilabel(lg,'Text','','FontSize',9,'FontWeight','bold','FontColor',[0.55 0.1 0.1]);
c.batch_preview.Layout.Row=row; c.batch_preview.Layout.Column=[1 2];
row=row+1; lbl2(lg,row,'Output folder:');
row=row+1; c.batch_out_dir = wide_txt(lg,row,'');
row=row+1;
c.batch_btn = wide_btn(lg,row,'Run batch filter + HTML report',[0.55 0.1 0.1],'white');
c.batch_btn.ButtonPushedFcn = @(~,~) do_batch_filter();

% ============================================================
% CENTRE PANEL — spatial + histograms
% ============================================================
cp = uipanel(gl,'Title','Overview');
cp.Layout.Column = 2;
cg = uigridlayout(cp,[2 3],...
    'RowHeight',{'3x','1x'},'ColumnWidth',{'1x','1x','1x'},...
    'Padding',[4 4 4 4],'RowSpacing',4);

ax_sp = uiaxes(cg);
ax_sp.Layout.Row=1; ax_sp.Layout.Column=[1 3];
ax_sp.XLabel.String='X (um)'; ax_sp.YLabel.String='Y (um)';
ax_sp.YDir = 'reverse';   % match ImageJ: Y increases downward
ax_sp.FontSize=9; hold(ax_sp,'on'); box(ax_sp,'on');
ax_sp.ButtonDownFcn = @on_spatial_click;
% NON-modal zoom/pan so a plain click always selects a track: scroll = zoom,
% drag = pan, single click = select. (The toolbar zoom/pan BUTTONS are modal and
% would swallow selection clicks, so only 'restoreview'/'export' are kept.)
ax_sp.Toolbar = axtoolbar(ax_sp,{'restoreview','export'});
ax_sp.Interactions = [zoomInteraction panInteraction];

ax_hd = uiaxes(cg);   % disp variance histogram (NND histogram removed)
ax_hd.Layout.Row=2; ax_hd.Layout.Column=1;
ax_hd.XLabel.String='Disp variance'; ax_hd.YLabel.String='N';
ax_hd.FontSize=8; hold(ax_hd,'on'); box(ax_hd,'on');
ax_hd.Title.String='Disp variance distribution';

ax_hdn = uiaxes(cg);   % local-density histogram (the primary crowding filter)
ax_hdn.Layout.Row=2; ax_hdn.Layout.Column=[2 3];
ax_hdn.XLabel.String='Local density'; ax_hdn.YLabel.String='N';
ax_hdn.FontSize=8; hold(ax_hdn,'on'); box(ax_hdn,'on');
ax_hdn.Title.String='Local density distribution';

% ============================================================
% RIGHT PANEL — selected track detail
% ============================================================
rp = uipanel(gl,'Title','Selected track');
rp.Layout.Column = 3;
rg = uigridlayout(rp,[3 1],...
    'RowHeight',{'2x','1x','1x'},...
    'Padding',[4 4 4 4],'RowSpacing',4);

ax_tr = uiaxes(rg); ax_tr.Layout.Row=1;
ax_tr.XLabel.String='X (um)'; ax_tr.YLabel.String='Y (um)';
ax_tr.YDir = 'reverse';   % match ImageJ orientation
ax_tr.FontSize=8; hold(ax_tr,'on'); box(ax_tr,'on');
% No zoom/pan MODES here: this axes is redrawn every playback frame (timer), and
% interaction modes try to set WindowButtonUpFcn, which errors on an embedded
% uifigure ("mode is active" / FigureModeData). Static, non-interactive.
disableDefaultInteractivity(ax_tr);
ax_tr.Toolbar.Visible = 'off';

ax_dv2 = uiaxes(rg); ax_dv2.Layout.Row=2;
ax_dv2.XLabel.String='Time (s)'; ax_dv2.YLabel.String='Step (um)';
ax_dv2.FontSize=8; hold(ax_dv2,'on');

ax_in = uiaxes(rg); ax_in.Layout.Row=3;
ax_in.XLabel.String='Time (s)'; ax_in.YLabel.String='Intensity';
ax_in.FontSize=8; hold(ax_in,'on');

% ---- embedded: default the Export destinations to the pipeline's tracks/ ----
if nargin >= 2 && ~isempty(exportDir)
    c.export_dir.Value    = exportDir;
    c.batch_out_dir.Value = exportDir;
    % auto-load the tracks folder so single-file view AND batch filter work right away
    % (otherwise "Run batch filter" hits "No files loaded" until you Select folder).
    if isfolder(exportDir), try, load_folder(exportDir); catch, end, end
end

% ============================================================
% CALLBACKS
% ============================================================

    % ---- Folder load ----------------------------------------
    function do_load_folder()
        folder = uigetdir('.','Select folder containing XML and CSV files');
        if isequal(folder,0), return, end
        load_folder(folder);
    end

    function load_folder(folder)
        % Populate S.file_list from a folder's raw *_tracks.xml + *_spots.csv pairs
        % (shared by the "Select folder" button AND the embedded auto-load, so batch
        % filter / navigation work immediately in the app without a second folder pick).
        if isempty(folder) || ~isfolder(folder)
            c.status.Text = 'Folder not found.'; return
        end
        % Choose which pair to read: Tool 1's curated _filtered pair (readPrefer='filtered', if
        % present) or the raw TrackMate _tracks.xml. Never read our own _<exportSuffix> output.
        useFiltered = strcmp(S.readPrefer,'filtered') && ~isempty(dir(fullfile(folder,'*_tracks_filtered.xml')));
        if useFiltered
            xmlSuffix = '_tracks_filtered.xml'; csvSuffix = '_spots_filtered.csv';
            xml_files = dir(fullfile(folder,'*_tracks_filtered.xml'));
            xml_files = xml_files(~contains({xml_files.name},'builtin'));
        else
            xmlSuffix = '_tracks.xml'; csvSuffix = '_spots.csv';
            xml_files = dir(fullfile(folder,'*_tracks.xml'));
            xml_files = xml_files(~contains({xml_files.name},'builtin') & ~contains({xml_files.name},'filtered'));
        end
        xesc = regexptranslate('escape', xmlSuffix);
        % session cell selection (Experiment "work" ticks): keep only the chosen cell bases
        if ~isempty(S.incFiles) && ~isempty(xml_files)
            keep = false(1,numel(xml_files));
            for k = 1:numel(xml_files)
                b = regexprep(xml_files(k).name,[xesc '$'],'');
                keep(k) = any(cellfun(@(x) ~isempty(x) && (strcmpi(x,b) || contains(b,x) || contains(x,b)), S.incFiles));
            end
            xml_files = xml_files(keep);
        end
        if isempty(xml_files)
            c.status.Text = ['No *' xmlSuffix ' files found in the tracks folder.']; return
        end
        S.file_list = {};
        for k = 1:numel(xml_files)
            base     = regexprep(xml_files(k).name,[xesc '$'],'');
            csv_path = fullfile(folder,[base csvSuffix]);
            blt_path = fullfile(folder,[base '_tracks_builtin.xml']);
            if isfile(csv_path)
                blt = ''; if isfile(blt_path), blt = blt_path; end
                S.file_list{end+1} = {fullfile(folder,xml_files(k).name), csv_path, base, blt};
            end
        end
        if isempty(S.file_list)
            c.status.Text = ['Found *' xmlSuffix ' but no matching *' csvSuffix '.']; return
        end
        S.current_file = 1;
        c.status.Text = sprintf('Found %d file pairs. Loading first...', numel(S.file_list));
        drawnow;
        load_file(S.current_file);
    end

    function nav_file(delta)
        if isempty(S.file_list), return, end
        S.current_file = max(1, min(numel(S.file_list), S.current_file + delta));
        load_file(S.current_file);
    end

    % ---- Single file load -----------------------------------
    function do_load_single()
        xml_path = strtrim(strjoin(c.xml.Value,''));
        csv_path = strtrim(strjoin(c.csv.Value,''));
        if ~isfile(xml_path), c.status.Text=['XML not found: ' xml_path]; return, end
        if ~isfile(csv_path), c.status.Text=['CSV not found: ' csv_path]; return, end
        [fdir,base] = fileparts(xml_path);
        base = regexprep(base,'_tracks$','');
        blt_path = fullfile(fdir,[base '_tracks_builtin.xml']);
        blt = ''; if isfile(blt_path), blt = blt_path; end
        S.file_list = {{xml_path, csv_path, base, blt}};
        S.current_file = 1;
        load_file(1);
    end

    % ---- Core load + compute --------------------------------
    function load_file(idx)
        do_pause();
        info     = S.file_list{idx};
        xml_path = info{1}; csv_path = info{2}; base_name = info{3};
        n_files  = numel(S.file_list);
        c.file_lbl.Text = sprintf('[%d/%d]  %s',idx,n_files,base_name);
        c.status.Text = 'Loading...'; drawnow;
        auto_load_overlay(base_name);   % this cell's ER/mito overlay (clears the previous cell's)
        apply_tool1_settings(fileparts(xml_path), base_name);   % pull link/gap/frame-gap from Tool 1's _settings.txt

        % Spots CSV
        spots = readtable(csv_path,'TextType','string');
        spots = spots(~isnan(spots.SPOT_ID) & ~isnan(spots.FRAME),:);
        if ismember('TRACK_ID',spots.Properties.VariableNames)
            spots_j = removevars(spots,'TRACK_ID');
        else
            spots_j = spots;
        end
        % Ensure numeric
        spots_j.SPOT_ID = double(spots_j.SPOT_ID);
        spots_j.FRAME   = double(spots_j.FRAME);
        spots_j.X_um    = double(spots_j.X_um);
        spots_j.Y_um    = double(spots_j.Y_um);

        % XML
        xdoc   = xmlread(xml_path);
        root   = xdoc.getDocumentElement();
        fi_val = str2double(root.getAttribute('frameInterval'));
        if isnan(fi_val)||fi_val==0, fi_val=1; end
        S.frame_interval = fi_val;

        tnodes = xdoc.getElementsByTagName('Track');
        n_tr   = tnodes.getLength();
        if n_tr==0, c.status.Text='No tracks in XML.'; return, end

        tids=[]; sids=[];
        for ti=0:n_tr-1
            tn  = tnodes.item(ti);
            tid = str2double(tn.getAttribute('TRACK_ID'));
            sn  = tn.getElementsByTagName('Spot');
            for si=0:sn.getLength()-1
                tids(end+1,1)=tid;
                sids(end+1,1)=str2double(sn.item(si).getAttribute('SPOT_ID'));
            end
        end
        tdf = table(tids,sids,'VariableNames',{'TRACK_ID','SPOT_ID'});

        % Join
        spots_t = outerjoin(tdf,spots_j,'Keys','SPOT_ID','MergeKeys',true,'Type','left');
        spots_t = spots_t(~isnan(spots_t.FRAME),:);
        spots_t = sortrows(spots_t,{'TRACK_ID','FRAME'});

        c.status.Text='Computing density metrics...'; drawnow;

        % Crowding + motion metrics — local density (worst-case = densest frame) measured at
        % the LINKING radius, so a track is flagged when spots fell inside the window the linker
        % actually searched. Shared with
        % the batch filter + recomputed when the tracking-parameter fields change.
        S.spots_t       = spots_t;
        tm              = compute_metrics_from_spots(spots_t);
        track_ids       = tm.TRACK_ID;
        n_t             = height(tm);
        S.track_metrics = tm;
        S.xml_doc       = xdoc;
        S.kept_ids      = track_ids;
        S.manual_keep   = [];   % new dataset -> no overrides yet
        S.manual_reject = [];
        S.selected_id   = [];
        S.loaded        = true;
        S.filter_log    = {};   % reset filter history for new file

        % Load builtin XML if available
        blt_path = info{4};
        if ~isempty(blt_path) && isfile(blt_path)
            S.builtin_xml_doc = xmlread(blt_path);
        else
            S.builtin_xml_doc = [];
        end

        % Update slider ranges
        dv_max  = max(tm.disp_variance,[],'omitnan');
        dn_max  = max(tm.mean_local_density);
        if ~isnan(dv_max) && dv_max>0
            c.max_dv.Limits=[0 dv_max*1.1]; c.max_dv.Value=dv_max*1.1;
        end
        if dn_max>0
            c.max_dn.Limits=[0 dn_max+1]; c.max_dn.Value=dn_max+1;
        end

        c.status.Text = sprintf('Loaded: %d tracks | %d spots | dt=%.4fs',...
            n_t, height(spots_t), S.frame_interval);

        update_histograms();
        updateFilterLabels();
        refresh_thresh_labels();   % show each percentile's threshold value for THIS file
        do_reshuffle();
    end

    % ---- Metric computation (shared: load + batch + param change) -----------
    function R = metric_R()
        % crowding radius = the linking distance from your TrackMate run (was hardcoded 1.0)
        R = DENSITY_RADIUS;
        if isfield(c,'link_dist') && isgraphics(c.link_dist), R = c.link_dist.Value; end
    end

    function tm = compute_metrics_from_spots(spots_t)
        % Per-spot local density (# other spots within the linking radius R, same frame).
        % Per track: density = MAX over its spots (worst-case crowding) — so a track that dips
        % into ONE crowded frame is flagged, not averaged away. Plus displacement variance,
        % the max single-step jump, and confinement.
        R = metric_R();
        frames = unique(spots_t.FRAME);
        dens_v = zeros(height(spots_t),1);
        for fi=1:numel(frames)
            idx = find(spots_t.FRAME==frames(fi));
            if numel(idx)<=1, continue, end
            xy = [spots_t.X_um(idx), spots_t.Y_um(idx)];
            D  = pdist2(xy,xy); D(eye(size(D))==1)=Inf;
            dens_v(idx) = sum(D<=R,2);          % # other spots within the linking radius, same frame
        end
        spots_t.LOCAL_DENSITY = dens_v;

        track_ids = unique(spots_t.TRACK_ID); n_t = numel(track_ids);
        TRACK_ID=track_ids; n_spots=zeros(n_t,1); x_mean=zeros(n_t,1); y_mean=zeros(n_t,1);
        frame_start=zeros(n_t,1); frame_end=zeros(n_t,1); mean_quality=zeros(n_t,1);
        mean_local_density=zeros(n_t,1);
        disp_variance=nan(n_t,1); max_step_um=nan(n_t,1); confinement=nan(n_t,1);
        for ti=1:n_t
            r = sortrows(spots_t(spots_t.TRACK_ID==track_ids(ti),:),'FRAME');
            n_spots(ti)=height(r); x_mean(ti)=mean(r.X_um); y_mean(ti)=mean(r.Y_um);
            frame_start(ti)=min(r.FRAME); frame_end(ti)=max(r.FRAME);
            mean_quality(ti)=mean(r.QUALITY,'omitnan');
            mean_local_density(ti) = max(r.LOCAL_DENSITY,[],'omitnan'); % worst-case: densest frame
            if height(r)>=2
                dx=diff(r.X_um); dy=diff(r.Y_um); d=sqrt(dx.^2+dy.^2);
                disp_variance(ti)=var(d); max_step_um(ti)=max(d);
                e2e=sqrt((r.X_um(end)-r.X_um(1))^2+(r.Y_um(end)-r.Y_um(1))^2); pl=sum(d);
                if pl>0, confinement(ti)=e2e/pl; end
            end
        end
        tm = table(TRACK_ID,n_spots,x_mean,y_mean,frame_start,frame_end,mean_quality, ...
            mean_local_density,disp_variance,max_step_um,confinement);
    end

    function on_param_change()
        % a tracking-parameter field changed -> re-measure crowding at the new linking radius
        if ~S.loaded || isempty(S.spots_t), return; end
        S.track_metrics = compute_metrics_from_spots(S.spots_t);
        tm = S.track_metrics;
        dn = max(tm.mean_local_density);
        if dn>0, c.max_dn.Limits=[0 dn+1]; c.max_dn.Value=min(c.max_dn.Value,dn+1); end
        update_histograms(); preview_filter(); refresh_thresh_labels();
    end

    % ---- Histogram plots ------------------------------------
    function update_histograms()
        if ~S.loaded, return, end
        tm = S.track_metrics;

        % Disp variance histogram
        cla(ax_hd); hold(ax_hd,'on');
        dv_vals = tm.disp_variance(~isnan(tm.disp_variance));
        histogram(ax_hd, dv_vals, 40,'FaceColor',[0.91 0.30 0.24],...
            'EdgeColor','none','FaceAlpha',0.7);
        thresh_d = c.max_dv.Value;
        xline(ax_hd, thresh_d,'r--','LineWidth',1.5);
        ax_hd.Title.String = sprintf('Disp var  (threshold=%.4f)',thresh_d);
        ax_hd.XLabel.String='Disp variance'; ax_hd.YLabel.String='N tracks';

        % Local-density histogram
        cla(ax_hdn); hold(ax_hdn,'on');
        dn_vals = tm.mean_local_density(~isnan(tm.mean_local_density));
        % local density is an INTEGER neighbour count -> integer-centred bins so bars sit
        % exactly on 0,1,2,... (40 fractional bins made the 0-bar look like it was at ~0.1).
        histogram(ax_hdn, dn_vals, 'BinMethod','integers','FaceColor',[0.30 0.69 0.31],...
            'EdgeColor','none','FaceAlpha',0.7);
        thresh_dn = c.max_dn.Value;
        xline(ax_hdn, thresh_dn,'r--','LineWidth',1.5);
        ax_hdn.Title.String = sprintf('Density  (max=%.1f)',thresh_dn);
        ax_hdn.XLabel.String='Local density'; ax_hdn.YLabel.String='N tracks';
        drawnow limitrate;
    end

    % ---- Filter preview + apply -----------------------------
    function ids = filter_ids()
        tm   = S.track_metrics;
        keep = ids_from_abs_thresh(tm);   % shared with the batch → identical decision
        ids  = tm.TRACK_ID(keep);
    end

    function preview_filter()
        if ~S.loaded, return, end
        ids = filter_ids();
        ids = union(setdiff(ids, S.manual_reject), S.manual_keep);   % preview reflects manual keep/reject too
        n_k = numel(ids); n_t = height(S.track_metrics);
        nov = numel(S.manual_keep) + numel(S.manual_reject);
        if nov > 0
            c.filt_lbl.Text = sprintf('Keep %d / Reject %d / Total %d  (%d manual override%s)', ...
                n_k, n_t-n_k, n_t, nov, tern_(nov==1,'','s'));
        else
            c.filt_lbl.Text = sprintf('Keep %d / Reject %d / Total %d', n_k, n_t-n_k, n_t);
        end
        updateFilterLabels();
        update_histograms();
    end

    function y = tern_(c_,a_,b_), if c_, y=a_; else, y=b_; end, end

    function updateFilterLabels()
        if ~isfield(c,'lbl_dv'), return, end
        c.lbl_dv.Text  = sprintf('Max disp var: %.4f', c.max_dv.Value);
        c.lbl_dn.Text  = sprintf('Max density: %.0f',  c.max_dn.Value);
    end

    function refreshTraj()
        if S.loaded && ~isempty(S.selected_id)
            update_trajectory(S.current_frame);
        end
    end

    function apply_percentile_filter()
        if ~S.loaded, return, end
        tm = S.track_metrics;
        % Disp var: keep below given percentile
        p_dv = c.pct_dv.Value;
        dv_vals = sort(tm.disp_variance(~isnan(tm.disp_variance)));
        if ~isempty(dv_vals) && p_dv<100
            thresh_dv = prctile(dv_vals, p_dv);
            c.max_dv.Value = max(c.max_dv.Limits(1), ...
                min(c.max_dv.Limits(2), thresh_dv));
        end
        % Local density: keep below given percentile
        p_dn = c.pct_dn.Value;
        dn_vals = sort(tm.mean_local_density(~isnan(tm.mean_local_density)));
        if ~isempty(dn_vals) && p_dn<100
            thresh_dn = prctile(dn_vals, p_dn);
            c.max_dn.Value = max(c.max_dn.Limits(1), ...
                min(c.max_dn.Limits(2), thresh_dn));
        end
        preview_filter();
        refresh_thresh_labels();
    end

    function refresh_thresh_labels()
        % Show the ACTUAL threshold VALUE each single-file percentile helper maps to on the
        % current file, then a batch preview that uses the SAME absolute thresholds the batch
        % will apply to every file — so the preview here IS what the batch does.
        if ~S.loaded || isempty(S.track_metrics), return; end
        tm  = S.track_metrics;
        dv  = tm.disp_variance(~isnan(tm.disp_variance));
        dn  = tm.mean_local_density(~isnan(tm.mean_local_density));
        setpl(c.pctlbl_dv,    'Disp var keep below', c.pct_dv.Value,       dv, '',  '%.4f');
        setpl(c.pctlbl_dn,    'Density keep below',  c.pct_dn.Value,       dn, '',  '%.1f');
        % BATCH preview: how many tracks THIS cell keeps at the CURRENT absolute thresholds
        % (identical to filter_ids), so the number matches what the batch will export.
        if ~isempty(c.batch_preview) && isgraphics(c.batch_preview)
            keep = ids_from_abs_thresh(tm);
            nT=numel(keep); nK=sum(keep);
            c.batch_preview.Text = sprintf('This cell → keep %d / %d  (%.0f%%),  reject %d', nK, nT, 100*nK/max(nT,1), nT-nK);
        end
    end

    function keep = ids_from_abs_thresh(tm)
        % The single source of truth for the keep/reject decision from the absolute
        % thresholds (Max disp var, Max density, jump gate). Used by both the interactive
        % filter and the batch, so single-file and batch are guaranteed identical.
        keep = true(height(tm),1);
        keep = keep & (isnan(tm.disp_variance)      | tm.disp_variance      <= c.max_dv.Value);
        keep = keep & (isnan(tm.mean_local_density) | tm.mean_local_density <= c.max_dn.Value);
        if isfield(c,'reject_jumps') && isgraphics(c.reject_jumps) && c.reject_jumps.Value ...
                && ismember('max_step_um',tm.Properties.VariableNames)
            keep = keep & (isnan(tm.max_step_um) | tm.max_step_um <= c.gap_dist.Value);
        end
    end

    function setpl(h, txt, p, vals, unit, fmt)
        if isempty(h) || ~isgraphics(h), return; end
        if isempty(vals), h.Text = sprintf('%s p%g:', txt, p); return; end
        v = prctile(vals, p);
        h.Text = sprintf(['%s p%g  = ' fmt '%s'], txt, p, v, unit);
    end

    function closeIfValid(d)
        if ~isempty(d) && isvalid(d), close(d); end   % onCleanup guard for the batch progress bar
    end

    function do_apply_filter()
        if ~S.loaded, return, end
        prev_kept = S.kept_ids;
        % filter from the sliders, THEN re-apply the user's manual keep/reject on
        % top so hand overrides survive a filter re-apply (filter + manual coexist).
        S.kept_ids = filter_ids();
        S.kept_ids = union(setdiff(S.kept_ids, S.manual_reject), S.manual_keep);
        n_k=numel(S.kept_ids); n_t=height(S.track_metrics);
        nov = numel(S.manual_keep)+numel(S.manual_reject);
        c.filt_lbl.Text = sprintf('Applied: %d kept, %d rejected (%d manual overrides kept)', ...
            n_k,n_t-n_k,nov);

        % Log this filter action
        newly_removed = setdiff(prev_kept, S.kept_ids);
        if ~isempty(newly_removed)
            entry.action      = 'auto_filter';
            entry.timestamp   = datestr(now,'yyyy-mm-dd HH:MM:SS');
            entry.max_dv      = c.max_dv.Value;
            entry.max_dn      = c.max_dn.Value;
            entry.pct_dv      = c.pct_dv.Value;
            entry.removed_ids = newly_removed';
            entry.n_removed   = numel(newly_removed);
            entry.n_kept      = n_k;
            S.filter_log{end+1} = entry;
        end
        do_reshuffle();
    end

    % ---- Spatial overview -----------------------------------
    function do_reshuffle()
        if ~S.loaded, return, end
        rng(S.resample_seed); S.resample_seed=S.resample_seed+1;
        if c.kept_chk.Value
            pool = S.kept_ids;
        else
            pool = S.track_metrics.TRACK_ID;
        end
        n_show = min(c.max_shown.Value, numel(pool));
        idx3   = randperm(numel(pool),n_show);
        S.shown_ids = pool(idx3);
        if ~isempty(S.selected_id) && ~ismember(S.selected_id,S.shown_ids)
            S.shown_ids=[S.shown_ids;S.selected_id];
        end
        update_spatial();
    end

    function update_spatial()
        if ~S.loaded, return, end
        cla(ax_sp); hold(ax_sp,'on');
        fr = []; if ~isempty(S.selected_id), fr = S.current_frame; end   % track selected -> overlay at its frame
        S.ovH_sp = draw_structure_overlay(ax_sp, fr);
        for k=1:numel(S.shown_ids)
            tid=S.shown_ids(k);
            r2=S.spots_t(S.spots_t.TRACK_ID==tid,:);
            if height(r2)<2, continue, end
            col = track_color('col_kept','blue');
            if ~ismember(tid,S.kept_ids), col = track_color('col_excl','red'); end   % excluded
            plot(ax_sp,r2.X_um,r2.Y_um,'-','Color',[col 0.55],...
                'LineWidth',0.5,'HitTest','off');
        end
        if ~isempty(S.selected_id)
            r2=S.spots_t(S.spots_t.TRACK_ID==S.selected_id,:);
            plot(ax_sp,r2.X_um,r2.Y_um,'-','Color',[1 0.84 0],...
                'LineWidth',2,'HitTest','off');
        end
        n_t=height(S.track_metrics);
        title(ax_sp,sprintf('%d/%d shown | %d kept %d rejected',...
            numel(S.shown_ids),n_t,numel(S.kept_ids),n_t-numel(S.kept_ids)),...
            'FontSize',9);
        drawnow limitrate;
    end

    % ---- Structure overlay (ER / mito) ----------------------
    function ov = load_overlay_stack(fp)
        % Load a TIFF for overlay. Returns .mip (whole-movie occupancy for a segmentation mask, else
        % a plain MIP for a raw structure image) plus the stack path/pages/fg-label, so the playback
        % view can draw the mask AT a given frame instead of a time-smeared projection.
        ov = struct('mip',[],'path','','nfr',0,'fg',[],'isMask',false);
        if isempty(fp) || exist(fp,'file')~=2, return; end
        info=imfinfo(fp); n=numel(info);
        a1=imread(fp,1); vals=unique(a1(:)); nz=vals(vals>0);
        ov.isMask = numel(vals)<=10;                       % few levels -> a segmentation / label map
        if ov.isMask && ~isempty(nz), ov.fg=min(nz); end    % fg = min nonzero (1 for label map, 255 for 0/255)
        % Overview = FIRST frame (a clean snapshot). The playback view shows the mask evolving per frame
        % (a whole-movie occupancy of a moving organelle just fills the FOV, which is not informative).
        if ov.isMask && ~isempty(ov.fg), ov.mip = double(a1==ov.fg); else, ov.mip = double(a1); end
        ov.path=fp; ov.nfr=n;
    end

    function set_overlay(kind, ov)
        S.([kind '_img'])=ov.mip;  S.([kind '_path'])=ov.path; S.([kind '_nfr'])=ov.nfr;
        S.([kind '_fg'])=ov.fg;    S.([kind '_isMask'])=ov.isMask;
    end

    function clear_overlay(kind)
        S.([kind '_img'])=[]; S.([kind '_path'])=''; S.([kind '_nfr'])=0; S.([kind '_fg'])=[]; S.([kind '_isMask'])=false;
    end

    function img = overlayImage(kind, frame)
        % Image for `kind` at a 0-based track frame: the per-frame mask from the stack when a frame
        % is given and the stack has pages, else the whole-movie occupancy/MIP (the overview).
        img = [];
        p=S.([kind '_path']); nfr=S.([kind '_nfr']); fg=S.([kind '_fg']); isMask=S.([kind '_isMask']);
        if ~isempty(frame) && ~isempty(p) && nfr>=1
            fi = min(max(round(frame)+1,1), nfr);          % 0-based track frame -> 1-based TIFF page
            try
                raw = imread(p, fi);
                if isMask && ~isempty(fg), img=double(raw==fg); else, img=double(raw); end
                return;
            catch
            end
        end
        img = S.([kind '_img']);                            % overview fallback
    end

    function apply_tool1_settings(folder, base)
        % Populate the tracking-parameter fields (link / gap / max-frame-gap) from Tool 1's
        % <base>_settings.txt, so the crowding radius + jump gate use YOUR actual tracking params.
        f = fullfile(folder, [base '_settings.txt']);
        if exist(f,'file')~=2, return; end
        try, txt = fileread(f); catch, return; end
        setnum = @(fld, key) local_set_spinner(fld, local_settings_num(txt, key));
        setnum('link_dist',      'tracking.link_um');
        setnum('gap_dist',       'tracking.max_gap_um');
        setnum('max_frame_gap',  'tracking.max_gap_frames');
    end

    function local_set_spinner(fld, val)
        if isnan(val) || ~isfield(c,fld) || ~isgraphics(c.(fld)), return; end
        lim = c.(fld).Limits; c.(fld).Value = min(max(val, lim(1)), lim(2));
    end

    function x = local_settings_num(txt, key)
        x = NaN;
        m = regexp(txt, [regexptranslate('escape',key) '\s*=\s*([-\d.eE+]+)'], 'tokens', 'once');
        if ~isempty(m), x = str2double(m{1}); end
    end

    function auto_load_overlay(base)
        % Resolve THIS cell's ER + mito stacks from the host's resolver and load them,
        % replacing the previous cell's overlay (fixes the "leftover from past" overlay).
        clear_overlay('er'); clear_overlay('mito'); clear_overlay('spt'); S.spt_hi=[];
        if isempty(S.overlayFcn), return; end
        try, ov = S.overlayFcn(base); catch, ov=[]; end
        if isempty(ov) || ~isstruct(ov), return; end
        try, if isfield(ov,'er')   && ~isempty(ov.er),   set_overlay('er',   load_overlay_stack(ov.er));   end, catch, end
        try, if isfield(ov,'mito') && ~isempty(ov.mito), set_overlay('mito', load_overlay_stack(ov.mito)); end, catch, end
        % raw SPT movie: keep it a full-intensity image (never treat as a mask) + a robust display max.
        try
            if isfield(ov,'spt') && ~isempty(ov.spt)
                sov = load_overlay_stack(ov.spt); sov.isMask=false; sov.fg=[];
                set_overlay('spt', sov);
                if ~isempty(S.spt_img), v=double(S.spt_img(:)); S.spt_hi=prctile(v(isfinite(v)),99.9); if ~(S.spt_hi>0), S.spt_hi=max(v); end, end
            end
        catch
        end
        haveE=~isempty(S.er_img); haveM=~isempty(S.mito_img);
        if haveE||haveM
            parts={}; if haveE, parts{end+1}='ER'; end; if haveM, parts{end+1}='mito'; end %#ok<AGROW>
            pf=''; if (S.er_nfr>1)||(S.mito_nfr>1), pf='  (per-frame)'; end
            c.ov_lbl.Text=['Auto overlay: ' strjoin(parts,' + ') pf '  (Experiment tab folders)'];
        else
            c.ov_lbl.Text='No ER/mito found for this cell (set folders on the Experiment tab, or Pick manually).';
        end
    end

    function pick_overlay(kind)
        [fn,pth]=uigetfile({'*.tif;*.tiff','TIFF images'}, ...
            ['Pick ' kind ' (raw stack, MIP, or segmented mask)']);
        if isequal(fn,0), return, end
        fp=fullfile(pth,fn);
        try, ov=load_overlay_stack(fp); catch ME, c.ov_lbl.Text=['Could not read image: ' ME.message]; return, end
        if isempty(ov.mip), c.ov_lbl.Text='Could not read image.'; return; end
        set_overlay(kind, ov);
        note='image'; if ov.isMask, note='mask'; end
        pf=', MIP'; if ov.nfr>1, pf=sprintf(', %d pg -> per-frame', ov.nfr); end
        c.ov_lbl.Text=sprintf('%s: %s  [%dx%d%s, %s]  spans %.4g um', ...
            kind,fn,size(ov.mip,1),size(ov.mip,2),pf,note,c.ov_fov.Value);
        if S.loaded, update_spatial(); end
    end

    function h = draw_structure_overlay(ax, frame)
        % frame (0-based, optional): draw the ER/mito masks AT that frame (else the overview first
        % frame). Semi-transparent (AlphaData) so the WHITE background shows through where there is no
        % organelle and the tracks stay visible on top. Returns the image handle (to retint per frame).
        if nargin<2, frame=[]; end
        h = [];
        [rgb, alpha] = overlay_rgba(frame);
        if isempty(rgb), return, end
        fov = c.ov_fov.Value; H=size(rgb,1); W=size(rgb,2);
        h = image('Parent',ax,'XData',[0 fov],'YData',[0 fov*H/W], ...
            'CData',rgb,'AlphaData',alpha,'HitTest','off');   % tint only the organelle; rest transparent
        uistack(h,'bottom');                                   % keep the overlay under the tracks
        ax.DataAspectRatio=[1 1 1];
    end

    function [rgb, alpha] = overlay_rgba(frame)
        % ER + mito as an RGB image (colours from the dropdowns), per-pixel opacity 0.5 on the
        % organelle foreground and 0 elsewhere. `frame` (0-based) selects the mask page; [] = first frame.
        rgb=[]; alpha=[];
        showER   = c.er_chk.Value   && ~isempty(S.er_img);
        showMito = c.mito_chk.Value && ~isempty(S.mito_img);
        if ~showER && ~showMito, return, end
        mI=[]; eI=[];
        if showMito, mI=overlayImage('mito',frame); end
        if showER,   eI=overlayImage('er',  frame); end
        ref=mI; if isempty(ref), ref=eI; end
        if isempty(ref), return, end
        H=size(ref,1); W=size(ref,2); rgb=zeros(H,W,3); a=zeros(H,W);
        if showMito && ~isempty(mI) && isequal(size(mI),[H W]), rgb=add_channel(rgb,mI,track_color('col_mito','magenta')); a=max(a,normImg(mI)); end
        if showER   && ~isempty(eI) && isequal(size(eI),[H W]), rgb=add_channel(rgb,eI,track_color('col_er','green'));    a=max(a,normImg(eI)); end
        rgb=min(rgb,1);
        alpha = a * 0.5;   % semi-transparent where organelle
    end

    function on_color_change()
        if ~S.loaded, return, end
        update_spatial();
        if ~isempty(S.selected_id), update_trajectory(S.current_frame); end
    end

    function rgb = track_color(field, defname)
        % RGB for a colour dropdown (or the default if the control is missing)
        if isfield(c,field) && isgraphics(c.(field)), rgb = color_rgb(c.(field).Value); else, rgb = color_rgb(defname); end
    end

    function rgb = color_rgb(name)
        names = {'green','magenta','cyan','blue','red','orange','yellow','purple','grey','black'};
        rgbs  = [0 0.75 0; 0.90 0 0.90; 0 0.72 0.85; 0.10 0.45 0.95; 0.90 0.15 0.15; ...
                 1 0.55 0; 0.92 0.82 0; 0.60 0.20 0.80; 0.55 0.55 0.55; 0.15 0.15 0.15];
        i = find(strcmp(names, char(name)), 1); if isempty(i), i = 1; end
        rgb = rgbs(i,:);
    end

    function rgb = add_channel(rgb, img, col)
        if size(img,1)~=size(rgb,1) || size(img,2)~=size(rgb,2)
            c.ov_lbl.Text='Overlay: ER and mito sizes differ — one channel skipped. Use same-size (same-camera) images.';
            return
        end
        g=normImg(img);
        for ch=1:3, rgb(:,:,ch)=rgb(:,:,ch)+col(ch)*g; end
    end

    function g = normImg(img)
        if ndims(img)==3, img=mean(double(img),3); end   % collapse RGB to grayscale
        g=double(img); mn=min(g(:)); mx=max(g(:));
        if mx>mn, g=(g-mn)/(mx-mn); else, g=zeros(size(g)); end
    end

    function on_spatial_click(~,evt)
        if ~S.loaded, return, end
        pt = evt.IntersectionPoint(1:2);
        tm = S.track_metrics(ismember(S.track_metrics.TRACK_ID,S.shown_ids),:);
        d  = sqrt((tm.x_mean-pt(1)).^2+(tm.y_mean-pt(2)).^2);
        [md,mi]=min(d);
        if md>2.0, return, end
        S.selected_id=tm.TRACK_ID(mi);
        tm_sel=S.track_metrics(S.track_metrics.TRACK_ID==S.selected_id,:);
        S.current_frame=tm_sel.frame_start;
        st='KEEP'; if ~ismember(S.selected_id,S.kept_ids), st='REJECT'; end
        c.sel_lbl.Text=sprintf('Track %d [%s]\nSpots:%d Frames:%d-%d\nDispVar:%.4f  MaxDens:%.0f',...
            S.selected_id,st,tm_sel.n_spots,tm_sel.frame_start,tm_sel.frame_end,...
            tm_sel.disp_variance,tm_sel.mean_local_density);
        update_spatial();
        update_trajectory(S.current_frame);
        update_disp_plot();
        update_intensity_plot();
    end

    % ---- Trajectory -----------------------------------------
    function update_trajectory(f)
        if ~S.loaded||isempty(S.selected_id), return, end
        S.current_frame=f;
        cla(ax_tr); hold(ax_tr,'on');
        draw_structure_overlay(ax_tr, f);   % mito/ER masks AT this frame (moving-organelle correct)
        draw_raw_spt(ax_tr, f);             % raw SPT movie behind everything (uistacked to the very bottom)
        if ~isempty(S.ovH_sp) && isvalid(S.ovH_sp)   % retint the OVERVIEW overlay to this frame too
            [rgbF, aF] = overlay_rgba(f);
            if ~isempty(rgbF), set(S.ovH_sp, 'CData', rgbF, 'AlphaData', aF); end
        end
        sel=sortrows(S.spots_t(S.spots_t.TRACK_ID==S.selected_id,:),'FRAME');
        if height(sel)==0, return, end
        er   = c.emitter_rad.Value;   % emitter footprint radius (um)
        ring = c.nearby_rad.Value;    % link / confusion ring radius (um)
        pad  = max(ring*2, er*4);
        xl=[min(sel.X_um)-pad, max(sel.X_um)+pad];
        yl=[min(sel.Y_um)-pad, max(sel.Y_um)+pad];

        all_now=S.spots_t(S.spots_t.FRAME==f & ...
            S.spots_t.X_um>=xl(1) & S.spots_t.X_um<=xl(2) & ...
            S.spots_t.Y_um>=yl(1) & S.spots_t.Y_um<=yl(2),:);

        sel_now=sel(sel.FRAME==f,:);
        haveSel=height(sel_now)>0; selID=NaN; sx=NaN; sy=NaN;
        if haveSel, selID=sel_now.SPOT_ID(1); sx=sel_now.X_um(1); sy=sel_now.Y_um(1); end

        % Draw every spot at this frame at its true physical size: an inner solid
        % circle = the emitter footprint (the data carry no localisation
        % precision, so this is the detection radius you set), and a dashed outer
        % "link ring". Where two emitters' footprints or rings overlap, linking
        % can confuse them -> a direct visual cue for potential mislinkage.
        rawOn = isfield(c,'spt_chk') && isgraphics(c.spt_chk) && c.spt_chk.Value && ~isempty(S.spt_path);
        for k=1:height(all_now)
            x=all_now.X_um(k); y=all_now.Y_um(k);
            isSel = haveSel && all_now.SPOT_ID(k)==selID;
            near  = haveSel && ~isSel && hypot(x-sx,y-sy)<=ring;
            if rawOn && ~isSel && ~near, continue; end   % over the raw image, only ring the selected + nearby spots
            if isSel,     eCol=[0.85 0.60 0.00]; lw=1.6; fCol=[1 0.84 0];
            elseif near,  eCol=[0.91 0.42 0.14]; lw=1.2; fCol=[];
            else,         eCol=[0.55 0.55 0.55]; lw=1.0; fCol=[];
            end
            if rawOn && ~isempty(fCol), fCol=[]; end      % don't fill over the raw image (keep the spot visible)
            draw_circle(x,y,er,  eCol,'-', lw,  fCol);   % emitter footprint
            draw_circle(x,y,ring,eCol,':', 0.6, []);     % link / confusion ring
        end

        past=sel(sel.FRAME<=f,:); future=sel(sel.FRAME>=f,:);
        if height(future)>=2
            plot(ax_tr,future.X_um,future.Y_um,'--',...
                'Color',[0.6 0.6 0.6],'LineWidth',0.8,'HitTest','off');
        end
        if height(past)>=2
            plot(ax_tr,past.X_um,past.Y_um,'-',...
                'Color',[1 0.84 0],'LineWidth',1.8,'HitTest','off');
        end
        plot(ax_tr,sel.X_um(1),sel.Y_um(1),'^',...
            'Color',[0.18 0.80 0.44],'MarkerFaceColor',[0.18 0.80 0.44],...
            'MarkerSize',7,'HitTest','off');

        axis(ax_tr,'equal');          % keep circles round (X and Y both in um)
        xlim(ax_tr,xl); ylim(ax_tr,yl);
        title(ax_tr,sprintf('Track %d  t=%.3fs  f=%d   [emitter r=%.2f, ring=%.2f um]',...
            S.selected_id,f*S.frame_interval,f,er,ring),'FontSize',9);
        drawnow limitrate;
    end

    function draw_raw_spt(ax, frame)
        % Raw SPT movie frame as a grayscale background spanning the FOV; the axis limits crop it to the
        % track. Drawn at the very bottom so ER/mito + rings + trajectory sit on top. Plays per frame.
        if ~(isfield(c,'spt_chk') && isgraphics(c.spt_chk) && c.spt_chk.Value), return; end
        if isempty(S.spt_path) || S.spt_nfr<1, return; end
        img = overlayImage('spt', frame); if isempty(img), return; end
        hi = S.spt_hi; if isempty(hi) || ~(hi>0), hi=max(double(img(:))); if ~(hi>0), hi=1; end, end
        con = 0.5; if isfield(c,'spt_con') && isgraphics(c.spt_con), con=c.spt_con.Value; end
        g = min(max(double(img)/(hi*max(con,1e-3)),0),1);
        fov=c.ov_fov.Value; H=size(g,1); W=size(g,2);
        h=image('Parent',ax,'XData',[0 fov],'YData',[0 fov*H/W],'CData',repmat(g,[1 1 3]),'HitTest','off');
        uistack(h,'bottom'); ax.DataAspectRatio=[1 1 1];
    end

    function draw_circle(x,y,r,edgeCol,ls,lw,faceCol)
        if r<=0, return, end
        args = {'Parent',ax_tr,'Position',[x-r y-r 2*r 2*r],'Curvature',[1 1],...
                'EdgeColor',edgeCol,'LineWidth',lw,'LineStyle',ls,...
                'HitTest','off','PickableParts','none'};
        if ~isempty(faceCol), args=[args {'FaceColor',faceCol}]; end
        rectangle(args{:});
    end

    function update_disp_plot()
        if ~S.loaded||isempty(S.selected_id), return, end
        cla(ax_dv2); hold(ax_dv2,'on');
        sel=sortrows(S.spots_t(S.spots_t.TRACK_ID==S.selected_id,:),'FRAME');
        if height(sel)<2, return, end
        dx=diff(sel.X_um); dy=diff(sel.Y_um); d=sqrt(dx.^2+dy.^2);
        t_s=sel.FRAME(2:end)*S.frame_interval;
        plot(ax_dv2,t_s,d,'-o','Color',[0.20 0.60 0.86],...
            'MarkerSize',2,'LineWidth',0.8);
        yline(ax_dv2,mean(d),'--r','LineWidth',0.8);
        title(ax_dv2,'Step displacements','FontSize',9);
        drawnow limitrate;
    end

    function update_intensity_plot()
        if ~S.loaded||isempty(S.selected_id), return, end
        vn = S.spots_t.Properties.VariableNames;
        if ismember('TOTAL_INTENSITY',vn)
            icol='TOTAL_INTENSITY'; ylab='Total (integrated) intensity';
        elseif ismember('MEAN_INTENSITY',vn)
            icol='MEAN_INTENSITY';  ylab='Mean intensity';
        else
            return
        end
        cla(ax_in); hold(ax_in,'on');
        sel=sortrows(S.spots_t(S.spots_t.TRACK_ID==S.selected_id,:),'FRAME');
        t_s=sel.FRAME*S.frame_interval;
        plot(ax_in,t_s,sel.(icol),'-o',...
            'Color',[0.61 0.35 0.71],'MarkerFaceColor',[0.61 0.35 0.71],...
            'MarkerSize',3,'LineWidth',0.8);
        ax_in.YLabel.String=ylab;
        title(ax_in,'Integrated intensity — stepwise bleaching','FontSize',9);
        drawnow limitrate;
    end

    % ---- Toggle / play / export -----------------------------
    function do_toggle()
        if ~S.loaded||isempty(S.selected_id), return, end
        sid = S.selected_id;
        if ismember(sid,S.kept_ids)
            S.kept_ids=setdiff(S.kept_ids,sid); st='REJECT';
            entry.action    = 'manual_reject';
            S.manual_reject = union(S.manual_reject, sid);   % remember the override...
            S.manual_keep   = setdiff(S.manual_keep,  sid);  % ...and drop any opposite one
        else
            S.kept_ids=union(S.kept_ids,sid); st='KEEP';
            entry.action    = 'manual_keep';
            S.manual_keep   = union(S.manual_keep,   sid);
            S.manual_reject = setdiff(S.manual_reject,sid);
        end
        % Log the manual action
        entry.timestamp   = datestr(now,'yyyy-mm-dd HH:MM:SS');
        entry.track_id    = S.selected_id;
        entry.removed_ids = S.selected_id;
        entry.n_removed   = 1;
        entry.n_kept      = numel(S.kept_ids);
        entry.max_dv=NaN; entry.max_dn=NaN;
        entry.pct_dv=NaN;
        S.filter_log{end+1} = entry;

        c.sel_lbl.Text=regexprep(c.sel_lbl.Text,'\[(KEEP|REJECT)\]',['[' st ']']);
        update_spatial();
    end

    function do_play()
        if ~S.loaded||isempty(S.selected_id), return, end
        S.playing=true;
        S.play_timer=timer('ExecutionMode','fixedRate',...
            'Period',round(max(0.033,1/c.fps.Value)*1000)/1000,...   % ms precision (timer requires it)
            'TimerFcn',@(~,~) advance_frame());
        start(S.play_timer);
    end

    function do_pause()
        S.playing=false;
        if ~isempty(S.play_timer)&&isvalid(S.play_timer)
            stop(S.play_timer); delete(S.play_timer);
        end
    end

    function advance_frame()
        if ~S.loaded||~S.playing||isempty(S.selected_id), return, end
        tm_sel=S.track_metrics(S.track_metrics.TRACK_ID==S.selected_id,:);
        f_next=S.current_frame+1;
        if f_next>tm_sel.frame_end, f_next=tm_sel.frame_start; end
        update_trajectory(f_next);
    end

    function export_cloud(inCsv, good_ids, outCsv)
        % Write EVERY detection from inCsv, keeping TRACK_ID only for tracks in good_ids (blank for
        % dropped / untracked) — preserves the localization cloud (Tool 1's "all detections" rule).
        T = readtable(inCsv);
        if ~ismember('TRACK_ID', T.Properties.VariableNames)
            copyfile(inCsv, outCsv); return;
        end
        tid = T.TRACK_ID; if ~isnumeric(tid), tid = str2double(string(tid)); end
        keep = ismember(tid, good_ids);
        s = strings(height(T),1); s(keep) = string(tid(keep));   % kept -> id; others -> "" (blank)
        T.TRACK_ID = s;
        writetable(T, outCsv);
    end

    function ok = do_export(silent)
        if nargin<1, silent=false; end   % silent = no modal popup (for Export + Next)
        ok = false;
        if ~S.loaded, return, end
        out_dir=strtrim(strjoin(c.export_dir.Value,''));
        if isempty(out_dir)
            out_dir=uigetdir('.','Select output folder');
            if isequal(out_dir,0), return, end
        end
        if ~isfolder(out_dir), mkdir(out_dir); end

        good_ids   = S.kept_ids;
        all_ids    = S.track_metrics.TRACK_ID;
        removed_ids = setdiff(all_ids, good_ids);

        if ~isempty(S.file_list)
            base_name = S.file_list{S.current_file}{3};
        else
            base_name = 'output';
        end

        % 1. Track metrics CSV with KEEP flag
        tm = S.track_metrics;
        tm.KEEP = ismember(tm.TRACK_ID, good_ids);
        writetable(tm, fullfile(out_dir,[base_name '_track_metrics.csv']));

        % 2. Spots CSV. preserveCloud (Tool 2): re-read the INPUT csv so EVERY detection is kept
        % (the localization cloud), blanking TRACK_ID for dropped/untracked spots — matches Tool 1's
        % rule "localization = all detections, only tracks filtered". Else (legacy): kept-track spots only.
        spotsOut = fullfile(out_dir,[base_name '_spots_' S.exportSuffix '.csv']);
        if S.preserveCloud && ~isempty(S.file_list)
            export_cloud(S.file_list{S.current_file}{2}, good_ids, spotsOut);
        else
            spots_out = S.spots_t(ismember(S.spots_t.TRACK_ID,good_ids),:);
            spots_out = removevars(spots_out, intersect({'LOCAL_DENSITY'},spots_out.Properties.VariableNames));
            writetable(spots_out, spotsOut);
        end

        % 3. Filtered track IDs log — what was removed and why
        fid_log = fopen(fullfile(out_dir,[base_name '_filter_log.csv']),'w');
        fprintf(fid_log,'track_id,status,removed_by,timestamp,max_dv,max_dn,pct_dv\n');
        % All kept tracks
        for k=1:numel(good_ids)
            fprintf(fid_log,'%d,kept,—,—,—,—,—\n', good_ids(k));
        end
        % Removed tracks with reason from filter log
        for k=1:numel(S.filter_log)
            entry = S.filter_log{k};
            rids  = entry.removed_ids;
            for j=1:numel(rids)
                if ismember(rids(j), removed_ids)   % still removed (not re-added)
                    fprintf(fid_log,'%d,removed,%s,%s,%.4f,%.1f,%.0f\n',...
                        rids(j), entry.action, entry.timestamp,...
                        entry.max_dv, entry.max_dn, entry.pct_dv);
                end
            end
        end
        % Any removed tracks not in filter log (e.g. removed before first apply)
        logged_removed = [];
        for k=1:numel(S.filter_log)
            logged_removed = [logged_removed; S.filter_log{k}.removed_ids(:)]; %#ok
        end
        unaccounted = setdiff(removed_ids, logged_removed);
        for k=1:numel(unaccounted)
            fprintf(fid_log,'%d,removed,unknown,—,—,—,—\n', unaccounted(k));   % 7 cols, matches header
        end
        fclose(fid_log);

        % 4. Custom filtered XML (with SPOT_ID)
        xdoc = S.xml_doc; root = xdoc.getDocumentElement();
        fid = fopen(fullfile(out_dir,[base_name '_tracks_' S.exportSuffix '.xml']),'w');
        fprintf(fid,'<?xml version="1.0" encoding="UTF-8"?>\n');
        fprintf(fid,'<Tracks nTracks="%d" frameInterval="%s" spaceUnit="%s" timeUnit="%s">\n',...
            numel(good_ids),...
            char(root.getAttribute('frameInterval')),...
            char(root.getAttribute('spaceUnit')),...
            char(root.getAttribute('timeUnit')));
        tnodes = xdoc.getElementsByTagName('Track');
        for ti=0:tnodes.getLength()-1
            tn=tnodes.item(ti);
            tid=str2double(tn.getAttribute('TRACK_ID'));
            if ~ismember(tid,good_ids), continue, end
            fprintf(fid,'  <Track TRACK_ID="%d" N_SPOTS="%s">\n',...
                tid,char(tn.getAttribute('N_SPOTS')));
            sn=tn.getElementsByTagName('Spot');
            for si=0:sn.getLength()-1
                s=sn.item(si);
                fprintf(fid,'    <Spot SPOT_ID="%s" FRAME="%s" T="%s" X="%s" Y="%s" Z="%s"/>\n',...
                    char(s.getAttribute('SPOT_ID')),char(s.getAttribute('FRAME')),...
                    char(s.getAttribute('T')),char(s.getAttribute('X')),...
                    char(s.getAttribute('Y')),char(s.getAttribute('Z')));
            end
            fprintf(fid,'  </Track>\n');
        end
        fprintf(fid,'</Tracks>\n'); fclose(fid);

        % 5. Builtin TrackMate XML — filter particles matching good TRACK_IDs
        % The builtin XML uses <particle> nodes in order matching track indices.
        % We match by position: sort all_ids, find which positions are kept.
        if ~isempty(S.builtin_xml_doc)
            broot    = S.builtin_xml_doc.getDocumentElement();
            particles = S.builtin_xml_doc.getElementsByTagName('particle');
            n_part    = particles.getLength();

            % Map TRACK_ID order to particle order
            % TrackMate writes particles in ascending TRACK_ID order
            sorted_all  = sort(all_ids);
            sorted_good = sort(good_ids);

            fid2 = fopen(fullfile(out_dir,[base_name '_tracks_builtin_' S.exportSuffix '.xml']),'w');
            fprintf(fid2,'<?xml version="1.0" encoding="UTF-8"?>\n');
            fprintf(fid2,'<Tracks nTracks="%d" spaceUnits="%s" frameInterval="%s" timeUnits="%s"',... 
                numel(good_ids),...
                char(broot.getAttribute('spaceUnits')),...
                char(broot.getAttribute('frameInterval')),...
                char(broot.getAttribute('timeUnits')));
            gen = char(broot.getAttribute('generationDateTime'));
            frm = char(broot.getAttribute('from'));
            if ~isempty(gen), fprintf(fid2,' generationDateTime="%s"',gen); end
            if ~isempty(frm), fprintf(fid2,' from="%s"',frm); end
            fprintf(fid2,'>\n');

            for pi=0:n_part-1
                if pi >= numel(sorted_all), break, end
                tid = sorted_all(pi+1);
                if ~ismember(tid, sorted_good), continue, end
                part = particles.item(pi);
                detections = part.getElementsByTagName('detection');
                fprintf(fid2,'  <particle nSpots="%d">\n', detections.getLength());
                for di=0:detections.getLength()-1
                    det = detections.item(di);
                    fprintf(fid2,'    <detection t="%s" x="%s" y="%s" z="%s"/>\n',...
                        char(det.getAttribute('t')),...
                        char(det.getAttribute('x')),...
                        char(det.getAttribute('y')),...
                        char(det.getAttribute('z')));
                end
                fprintf(fid2,'  </particle>\n');
            end
            fprintf(fid2,'</Tracks>\n'); fclose(fid2);
        end

        n_removed = numel(removed_ids);
        if silent
            c.status.Text = sprintf('Exported %s: kept %d, removed %d  ->  %s', base_name, numel(good_ids), n_removed, out_dir);
        else
            msgbox(sprintf(['Exported to: %s\n\n'...
                'Kept: %d tracks\nRemoved: %d tracks\n\n'...
                'Files written:\n'...
                '  _track_metrics.csv  (KEEP column)\n'...
                '  _spots_filtered.csv\n'...
                '  _filter_log.csv  (per-track removal reason)\n'...
                '  _tracks_filtered.xml\n'...
                '  _tracks_builtin_filtered.xml'],...
                out_dir, numel(good_ids), n_removed), 'Export done');
        end
        ok = true;
    end

    function do_export_next()
        % per-cell convenience: export THIS cell (silently), then step to the next one.
        if ~do_export(true), return; end          % only advance if the export succeeded
        if ~isempty(S.file_list) && S.current_file < numel(S.file_list)
            nav_file(+1);
        else
            c.status.Text = 'Exported — this was the last cell.';
        end
    end

    % ---- Batch filter all files ------------------------------
    function do_batch_filter()
        if isempty(S.file_list)
            msgbox('No files loaded. Use Select folder first.','Batch filter');
            return
        end
        out_dir = strtrim(strjoin(c.batch_out_dir.Value,''));
        if isempty(out_dir)
            out_dir = uigetdir('.','Select batch output folder');
            if isequal(out_dir,0), return, end
        end
        if ~isfolder(out_dir), mkdir(out_dir); end

        % Absolute thresholds — the SAME ones the interactive Curate filter uses right now.
        thr_dv   = c.max_dv.Value;
        thr_dn   = c.max_dn.Value;
        jump_on  = isfield(c,'reject_jumps') && isgraphics(c.reject_jumps) && c.reject_jumps.Value;
        thr_jump = c.gap_dist.Value;
        n_files = numel(S.file_list);

        % visible progress bar (uifigure dialog); fall back to the status line if this
        % isn't a uifigure. Cancelable so a long batch can be stopped mid-run.
        hFig = ancestor(c.batch_btn,'matlab.ui.Figure'); dlg = [];
        if ~isempty(hFig) && isa(hFig,'matlab.ui.Figure')
            try, dlg = uiprogressdlg(hFig,'Title','Batch filter','Message','Starting…', ...
                    'Cancelable','on','Value',0); catch, dlg=[]; end
        end
        dlgGuard = onCleanup(@() closeIfValid(dlg)); %#ok<NASGU>   % never leave the bar stuck open
        c.status.Text = sprintf('Batch filtering %d files...', n_files);
        drawnow;

        batch_results = struct(...
            'base',{},'n_total',{},'n_kept',{},'n_removed',{},...
            'med_dv_all',{},'med_dv_kept',{},...
            'med_dn_all',{},'med_dn_kept',{},...
            'removed_ids',{});

        for fi = 1:n_files
            info     = S.file_list{fi};
            xml_path = info{1};
            csv_path = info{2};
            base_nm  = info{3};
            blt_path = info{4};

            c.status.Text = sprintf('[%d/%d] %s', fi, n_files, base_nm);
            if ~isempty(dlg) && isvalid(dlg)
                if dlg.CancelRequested
                    c.status.Text = sprintf('Batch cancelled after %d/%d files.', fi-1, n_files);
                    close(dlg); return
                end
                dlg.Value = (fi-1)/n_files;
                dlg.Message = sprintf('[%d/%d]  %s', fi, n_files, base_nm);
            end
            drawnow;

            try
                % Load spots
                spots = readtable(csv_path,'TextType','string');
                spots = spots(~isnan(spots.SPOT_ID) & ~isnan(spots.FRAME),:);
                if ismember('TRACK_ID',spots.Properties.VariableNames)
                    spots_j = removevars(spots,'TRACK_ID');
                else
                    spots_j = spots;
                end
                spots_j.SPOT_ID = double(spots_j.SPOT_ID);
                spots_j.FRAME   = double(spots_j.FRAME);
                spots_j.X_um    = double(spots_j.X_um);
                spots_j.Y_um    = double(spots_j.Y_um);

                % Parse XML
                xdoc_b  = xmlread(xml_path);
                root_b  = xdoc_b.getDocumentElement();
                fi_val  = str2double(root_b.getAttribute('frameInterval'));
                if isnan(fi_val)||fi_val==0, fi_val=1; end

                tnodes_b = xdoc_b.getElementsByTagName('Track');
                n_tr_b   = tnodes_b.getLength();
                if n_tr_b==0, continue, end

                tids_b=[]; sids_b=[];
                for ti=0:n_tr_b-1
                    tn_b = tnodes_b.item(ti);
                    tid_b= str2double(tn_b.getAttribute('TRACK_ID'));
                    sn_b = tn_b.getElementsByTagName('Spot');
                    for si=0:sn_b.getLength()-1
                        tids_b(end+1,1)=tid_b;
                        sids_b(end+1,1)=str2double(sn_b.item(si).getAttribute('SPOT_ID'));
                    end
                end
                tdf_b = table(tids_b,sids_b,'VariableNames',{'TRACK_ID','SPOT_ID'});
                spots_t_b = outerjoin(tdf_b,spots_j,'Keys','SPOT_ID',...
                    'MergeKeys',true,'Type','left');
                spots_t_b = spots_t_b(~isnan(spots_t_b.FRAME),:);
                spots_t_b = sortrows(spots_t_b,{'TRACK_ID','FRAME'});

                % Crowding + motion metrics — SAME function as the interactive filter, so the
                % batch measures density(max) at your linking radius identically.
                tm_b        = compute_metrics_from_spots(spots_t_b);
                track_ids_b = tm_b.TRACK_ID;
                n_tb        = height(tm_b);
                mean_dn_b   = tm_b.mean_local_density; % worst-case (max) density per track
                disp_var_b  = tm_b.disp_variance;

                % Apply the SAME absolute thresholds the interactive Curate filter uses — via
                % the shared helper, so batch == what you saw on the tuning cell.
                keep_mask    = ids_from_abs_thresh(tm_b);
                good_ids_b   = track_ids_b(keep_mask);
                removed_ids_b= track_ids_b(~keep_mask);

                % Export filtered custom XML
                fid_x = fopen(fullfile(out_dir,[base_nm '_tracks_filtered.xml']),'w');
                fprintf(fid_x,'<?xml version="1.0" encoding="UTF-8"?>\n');
                fprintf(fid_x,'<Tracks nTracks="%d" frameInterval="%.6f" spaceUnit="%s" timeUnit="%s">\n',...
                    numel(good_ids_b), fi_val,...
                    char(root_b.getAttribute('spaceUnit')),...
                    char(root_b.getAttribute('timeUnit')));
                for ti=0:tnodes_b.getLength()-1
                    tn_b = tnodes_b.item(ti);
                    tid_b= str2double(tn_b.getAttribute('TRACK_ID'));
                    if ~ismember(tid_b,good_ids_b), continue, end
                    fprintf(fid_x,'  <Track TRACK_ID="%d" N_SPOTS="%s">\n',...
                        tid_b, char(tn_b.getAttribute('N_SPOTS')));
                    sn_b = tn_b.getElementsByTagName('Spot');
                    for si=0:sn_b.getLength()-1
                        s_b=sn_b.item(si);
                        fprintf(fid_x,'    <Spot SPOT_ID="%s" FRAME="%s" T="%s" X="%s" Y="%s" Z="%s"/>\n',...
                            char(s_b.getAttribute('SPOT_ID')),char(s_b.getAttribute('FRAME')),...
                            char(s_b.getAttribute('T')),char(s_b.getAttribute('X')),...
                            char(s_b.getAttribute('Y')),char(s_b.getAttribute('Z')));
                    end
                    fprintf(fid_x,'  </Track>\n');
                end
                fprintf(fid_x,'</Tracks>\n'); fclose(fid_x);

                % Export builtin XML if available
                if ~isempty(blt_path) && isfile(blt_path)
                    blt_doc   = xmlread(blt_path);
                    blt_root  = blt_doc.getDocumentElement();
                    parts_b   = blt_doc.getElementsByTagName('particle');
                    sorted_all_b  = sort(track_ids_b);
                    fid_b2 = fopen(fullfile(out_dir,[base_nm '_tracks_builtin_filtered.xml']),'w');
                    fprintf(fid_b2,'<?xml version="1.0" encoding="UTF-8"?>\n');
                    fprintf(fid_b2,'<Tracks nTracks="%d" spaceUnits="%s" frameInterval="%s" timeUnits="%s">\n',...
                        numel(good_ids_b),...
                        char(blt_root.getAttribute('spaceUnits')),...
                        char(blt_root.getAttribute('frameInterval')),...
                        char(blt_root.getAttribute('timeUnits')));
                    for pi=0:parts_b.getLength()-1
                        if pi>=numel(sorted_all_b), break, end
                        if ~ismember(sorted_all_b(pi+1),good_ids_b), continue, end
                        part_b = parts_b.item(pi);
                        dets_b = part_b.getElementsByTagName('detection');
                        fprintf(fid_b2,'  <particle nSpots="%d">\n',dets_b.getLength());
                        for di=0:dets_b.getLength()-1
                            det_b=dets_b.item(di);
                            fprintf(fid_b2,'    <detection t="%s" x="%s" y="%s" z="%s"/>\n',...
                                char(det_b.getAttribute('t')),char(det_b.getAttribute('x')),...
                                char(det_b.getAttribute('y')),char(det_b.getAttribute('z')));
                        end
                        fprintf(fid_b2,'  </particle>\n');
                    end
                    fprintf(fid_b2,'</Tracks>\n'); fclose(fid_b2);
                end

                % Export filter log CSV (thresholds are the absolute cutoffs applied to all files)
                fid_l = fopen(fullfile(out_dir,[base_nm '_filter_log.csv']),'w');
                fprintf(fid_l,'track_id,status,max_disp_var,max_density,disp_variance,local_density\n');
                for ti2=1:n_tb
                    tid_b = track_ids_b(ti2);
                    st_b  = 'kept'; if ~ismember(tid_b,good_ids_b), st_b='removed'; end
                    fprintf(fid_l,'%d,%s,%.4f,%.1f,%.4f,%.1f\n',...
                        tid_b, st_b, thr_dv, thr_dn,...
                        disp_var_b(ti2), mean_dn_b(ti2));
                end
                fclose(fid_l);

                % Record for HTML report
                r_struct.base        = base_nm;
                r_struct.n_total     = n_tb;
                r_struct.n_kept      = numel(good_ids_b);
                r_struct.n_removed   = numel(removed_ids_b);
                r_struct.med_dv_all  = median(disp_var_b,'omitnan');
                r_struct.med_dv_kept = median(disp_var_b(keep_mask),'omitnan');
                r_struct.med_dn_all  = median(mean_dn_b,'omitnan');
                r_struct.med_dn_kept = median(mean_dn_b(keep_mask),'omitnan');
                r_struct.removed_ids = removed_ids_b';
                batch_results(end+1)  = r_struct; %#ok

            catch ME
                warning('Batch filter failed on %s: %s', base_nm, ME.message);
            end
        end

        % Write HTML report
        html_path = fullfile(out_dir,'batch_filter_report.html');
        write_html_report(batch_results, html_path, thr_dv, thr_dn, jump_on, thr_jump);

        if ~isempty(dlg) && isvalid(dlg), dlg.Value=1; dlg.Message='Done'; close(dlg); end
        c.status.Text = sprintf('Batch done: %d files. Report: %s', n_files, html_path);
        msgbox(sprintf('Batch filter complete.\n%d files processed.\n\nReport:\n%s',...
            n_files, html_path), 'Batch done');
    end

    % ---- HTML report writer ----------------------------------
    function write_html_report(results, html_path, thr_dv, thr_dn, jump_on, thr_jump)
        fid = fopen(html_path,'w');
        fprintf(fid,'<!DOCTYPE html><html><head><meta charset="utf-8">\n');
        fprintf(fid,'<title>Batch Filter Report</title>\n');
        fprintf(fid,'<style>\n');
        fprintf(fid,'body{font-family:-apple-system,Arial,sans-serif;margin:30px;background:#f9f9f9}\n');
        fprintf(fid,'h1{color:#2c3e50}h2{color:#555;font-size:14px;margin-top:24px}\n');
        fprintf(fid,'.meta{background:#ecf0f1;padding:12px;border-radius:6px;margin-bottom:20px;font-size:13px}\n');
        fprintf(fid,'table{border-collapse:collapse;width:100%%;background:white;');
        fprintf(fid,'box-shadow:0 1px 4px rgba(0,0,0,.1);border-radius:6px;overflow:hidden;margin-bottom:24px}\n');
        fprintf(fid,'th{background:#2c3e50;color:white;padding:8px 12px;text-align:left;font-size:12px}\n');
        fprintf(fid,'td{padding:7px 12px;border-bottom:1px solid #ecf0f1;font-size:12px}\n');
        fprintf(fid,'tr:last-child td{border-bottom:none}tr:hover td{background:#f0f4f8}\n');
        fprintf(fid,'.bar-wrap{background:#ddd;border-radius:3px;height:12px;width:120px;display:inline-block}\n');
        fprintf(fid,'.bar{background:#3498db;height:12px;display:inline-block;vertical-align:top}\n');
        fprintf(fid,'.bar-r{background:#e74c3c;height:12px;display:inline-block;vertical-align:top}\n');
        fprintf(fid,'.tag-k{color:#27ae60;font-weight:600}.tag-r{color:#e74c3c;font-weight:600}\n');
        fprintf(fid,'</style></head><body>\n');
        fprintf(fid,'<h1>Batch Filter Report</h1>\n');
        fprintf(fid,'<div class="meta">');
        fprintf(fid,'Same absolute thresholds applied to every file (identical to the interactive Curate filter).<br>');
        fprintf(fid,'<b>Max disp variance:</b> %.4f &nbsp;|&nbsp; ', thr_dv);
        fprintf(fid,'<b>Max local density:</b> %.1f &nbsp;|&nbsp; ', thr_dn);
        if jump_on
            fprintf(fid,'<b>Jump gate:</b> reject max step &gt; %.2f µm &nbsp;|&nbsp; ', thr_jump);
        else
            fprintf(fid,'<b>Jump gate:</b> off &nbsp;|&nbsp; ');
        end
        fprintf(fid,'<b>Files:</b> %d &nbsp;|&nbsp; ', numel(results));
        total_kept    = sum([results.n_kept]);
        total_removed = sum([results.n_removed]);
        fprintf(fid,'<b>Total tracks kept:</b> %d &nbsp;|&nbsp; ', total_kept);
        fprintf(fid,'<b>Total removed:</b> %d</div>\n', total_removed);

        % Summary table
        fprintf(fid,'<h2>Per-file summary</h2>\n');
        fprintf(fid,'<table><thead><tr>');
        fprintf(fid,'<th>File</th><th>Total</th><th>Kept</th><th>Removed</th>');
        fprintf(fid,'<th>%% kept</th>');
        fprintf(fid,'<th>Med DV (all)</th><th>Med DV (kept)</th>');
        fprintf(fid,'<th>Med dens (all)</th><th>Med dens (kept)</th>');
        fprintf(fid,'<th>Kept</th></tr></thead><tbody>\n');

        for k=1:numel(results)
            r = results(k);
            pct_kept = 100*r.n_kept/max(r.n_total,1);
            % bar fills to THIS file's own total (100% kept = full bar): blue = kept,
            % red = removed, so the segment lengths read as the kept/removed fraction.
            bar_w  = round(120 * r.n_kept / max(r.n_total,1));
            bar_wr = 120 - bar_w;
            fprintf(fid,'<tr>');
            fprintf(fid,'<td><code>%s</code></td>', r.base);
            fprintf(fid,'<td>%d</td>', r.n_total);
            fprintf(fid,'<td class="tag-k">%d</td>', r.n_kept);
            fprintf(fid,'<td class="tag-r">%d</td>', r.n_removed);
            fprintf(fid,'<td>%.1f%%</td>', pct_kept);
            fprintf(fid,'<td>%.4f</td>', r.med_dv_all);
            fprintf(fid,'<td>%.4f</td>', r.med_dv_kept);
            fprintf(fid,'<td>%.1f</td>', r.med_dn_all);
            fprintf(fid,'<td>%.1f</td>', r.med_dn_kept);
            fprintf(fid,['<td><div class="bar-wrap" title="%d kept / %d removed">' ...
                '<div class="bar" style="width:%dpx"></div>' ...
                '<div class="bar-r" style="width:%dpx"></div></div></td>'], r.n_kept, r.n_removed, bar_w, bar_wr);
            fprintf(fid,'</tr>\n');
        end
        fprintf(fid,'</tbody></table>\n');

        % Removed track IDs per file
        fprintf(fid,'<h2>Removed track IDs per file</h2>\n');
        fprintf(fid,'<table><thead><tr><th>File</th><th>N removed</th><th>Track IDs</th></tr></thead><tbody>\n');
        for k=1:numel(results)
            r = results(k);
            if r.n_removed==0
                id_str = '<span style="color:#aaa">none</span>';
            else
                ids_str_arr = arrayfun(@(x) num2str(x), r.removed_ids, 'UniformOutput',false);
                id_str = strjoin(ids_str_arr, ', ');
                if length(id_str)>200
                    id_str = [id_str(1:200) '... (' num2str(r.n_removed) ' total)'];
                end
            end
            fprintf(fid,'<tr><td><code>%s</code></td><td>%d</td><td style="font-size:11px">%s</td></tr>\n',...
                r.base, r.n_removed, id_str);
        end
        fprintf(fid,'</tbody></table>\n');

        fprintf(fid,'<p style="font-size:11px;color:#aaa;margin-top:20px">');
        fprintf(fid,'Generated %s</p>\n', datestr(now));
        fprintf(fid,'</body></html>\n');
        fclose(fid);
    end

    % ---- Send data to base workspace -------------------------
    function send_to_workspace()
        if ~S.loaded
            c.status.Text = 'No data loaded — nothing to send.';
            return
        end

        % Core tables
        assignin('base', 'spots_t',       S.spots_t);
        assignin('base', 'track_metrics', S.track_metrics);

        % Keep/reject vectors
        assignin('base', 'kept_ids',    S.kept_ids);
        assignin('base', 'rejected_ids', ...
            setdiff(S.track_metrics.TRACK_ID, S.kept_ids));

        % Track metrics with KEEP column appended
        tm = S.track_metrics;
        tm.KEEP = ismember(tm.TRACK_ID, S.kept_ids);
        assignin('base', 'track_metrics_with_keep', tm);

        % Filter log as a table (one row per filter action)
        if ~isempty(S.filter_log)
            actions    = cellfun(@(e) e.action,    S.filter_log, 'UniformOutput', false)';
            timestamps = cellfun(@(e) e.timestamp, S.filter_log, 'UniformOutput', false)';
            n_removed  = cellfun(@(e) e.n_removed, S.filter_log)';
            n_kept     = cellfun(@(e) e.n_kept,    S.filter_log)';
            filter_log_tbl = table(actions, timestamps, n_removed, n_kept, ...
                'VariableNames', {'action','timestamp','n_removed','n_kept'});
            assignin('base', 'filter_log', filter_log_tbl);
        end

        % Current file info
        if ~isempty(S.file_list) && S.current_file > 0
            info = S.file_list{S.current_file};
            assignin('base', 'current_file_base', info{3});
        end

        n_kept     = numel(S.kept_ids);
        n_rejected = height(S.track_metrics) - n_kept;
        c.status.Text = sprintf('Sent to workspace: spots_t, track_metrics, kept_ids, rejected_ids, track_metrics_with_keep');
        disp('=== track_viewer: data sent to base workspace ===');
        disp(['  spots_t              — ' num2str(height(S.spots_t))    ' spots']);
        disp(['  track_metrics        — ' num2str(height(S.track_metrics)) ' tracks']);
        disp(['  track_metrics_with_keep — same + KEEP column']);
        disp(['  kept_ids             — ' num2str(n_kept)     ' kept']);
        disp(['  rejected_ids         — ' num2str(n_rejected) ' rejected']);
        if ~isempty(S.filter_log)
            disp(['  filter_log           — ' num2str(numel(S.filter_log)) ' filter actions']);
        end
    end

    function on_close()
        do_pause();
        if ownFig && isvalid(fig), delete(fig); end
    end

end % track_viewer

% ============================================================
% UI HELPER FUNCTIONS (outside main function, shared)
% ============================================================
function sec_lbl(grid, row, txt)
    h = uilabel(grid,'Text',txt,'FontSize',8,'FontWeight','bold',...
        'FontColor',[0.4 0.4 0.4],'HorizontalAlignment','center',...
        'BackgroundColor',[0.88 0.88 0.88]);
    h.Layout.Row=row; h.Layout.Column=[1 2];
end

function h = lbl2(grid, row, txt)
    h = uilabel(grid,'Text',txt,'FontSize',9);
    h.Layout.Row=row; h.Layout.Column=[1 2];
end

function h = wide_btn(grid, row, txt, bg, fg)
    h = uibutton(grid,'Text',txt,'BackgroundColor',bg,'FontColor',fg,'FontSize',9);
    h.Layout.Row=row; h.Layout.Column=[1 2];
end

function h = half_btn(grid, row, col, txt, bg, fg)
    h = uibutton(grid,'Text',txt,'BackgroundColor',bg,'FontColor',fg,'FontSize',9);
    h.Layout.Row=row; h.Layout.Column=col;
end

function h = wide_txt(grid, row, val)
    h = uitextarea(grid,'Value',val,'FontSize',8);
    h.Layout.Row=row; h.Layout.Column=[1 2];
end

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

% tool1_track holds the shared imaging helpers (spt_ij_auto, spt_stack_range, spt_tiff_calib). The
% host adds it, but four smoke tests construct this viewer directly with only their own folder on the
% path, so add it here too rather than let those helpers be undefined.
try
    t1 = fullfile(fileparts(fileparts(fileparts(mfilename('fullpath')))), 'tool1_track');
    if isfolder(t1) && ~contains([path pathsep], [t1 pathsep]), addpath(t1); end
catch
end

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
% ---- link cuts (mislinkage repair) ----------------------------------------------------------
% A cut severs the link LEAVING one spot, splitting that chain in two. Cuts are stored as spot ids,
% not as track ids: SPOT_ID is stable for the life of a cell, whereas fragment track ids are derived.
% Each cut carries the id it minted, so ids never shift when a later cut is made elsewhere — an
% override or a selection on an existing fragment stays pointing at the same spots.
S.cuts          = struct('afterSpotId',{},'newId',{},'origId',{});
S.cuts_by_cell  = containers.Map('KeyType','char','ValueType','any');   % base -> cuts + the counter
S.nextFragId    = [];    % per-cell monotonic counter for minted fragment ids (never reused)
S.strip         = struct('spotId',[],'t0',[],'t1',[],'step',[],'gap',[]);   % edges currently drawn
S.linkIdx       = [];    % which link of the selected track the cursor sits on
S.playRange     = [];    % [f0 f1] — when set, playback loops this window instead of the whole track
S.linkLoop      = false; % true while looping across one link rather than the whole track
S.linkPad       = 2;     % frames shown either side of a link when playing across it
S.cloud         = [];    % [FRAME X_um Y_um] for EVERY detection, tracked or not — the crowding source

% Playback timers carry this tag so an instance can find and kill the ones a PREVIOUS instance
% leaked. A leaked timer is not merely untidy: its TimerFcn closes over that instance's workspace,
% so it keeps firing against a stale S long after its window is gone. Once this file gains a field
% the old S never had, every tick prints "Unrecognized field name" with line numbers from the NEW
% file — which reads as a bug in code that is actually fine.
TIMER_TAG = 'spt_track_viewer_play';
old_t = timerfindall('Tag', TIMER_TAG);
if ~isempty(old_t)
    for q = 1:numel(old_t)
        try, stop(old_t(q)); catch, end
        try, delete(old_t(q)); catch, end
    end
    warning('track_viewer:staleTimer', ...
        ['Stopped %d playback timer(s) left by a previous Import & Curate instance. ' ...
         'If you were seeing repeated errors in the console, that was them.'], numel(old_t));
end
S.manual_by_cell = containers.Map('KeyType','char','ValueType','any');  % base -> the two lists,
                         % so manual decisions survive switching cells AND a batch run
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
S.spt_img=[]; S.spt_path=''; S.spt_nfr=0; S.spt_fg=[]; S.spt_isMask=false; S.spt_hi=[]; S.spt_lo=[];  % raw SPT movie (selected-track background)
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
    'ColumnWidth',{322,'1x',340},...
    'Padding',[6 6 6 6],'ColumnSpacing',6,...
    'BackgroundColor',[0.95 0.95 0.95]);

% ============================================================
% LEFT PANEL — controls (scrollable) + an always-visible activity log
% ============================================================
lp = uipanel(gl,'Title','Controls','FontSize',10,'FontWeight','bold');
lp.Layout.Column = 1;
lpg = uigridlayout(lp,[2 1],'RowHeight',{'1x',108},'Padding',[0 0 0 0],'RowSpacing',4, ...
    'BackgroundColor',[0.97 0.97 0.97]);
lg = uigridlayout(lpg,[60 2],...
    'RowHeight',   repmat({22},1,60),...
    'ColumnWidth', {'fit','1x'},...
    'Scrollable','on',...
    'Padding',[5 4 5 4],'RowSpacing',2,...
    'BackgroundColor',[0.97 0.97 0.97]);
% the log lives OUTSIDE the scrollable grid so it never scrolls out of view — every long action
% (apply, toggle, export, batch) writes here, so a click always leaves a visible trace.
c.log = uitextarea(lpg,'Editable','off','FontSize',8.5,'FontName','Menlo', ...
    'Value',{'Curate log:'});

row = 0;

% -- Cell navigation. The tracks folder auto-loads from the project, so there is no manual
% XML+CSV picker any more: it predated the Tool 1 -> Tool 2 handoff and only invited loading a
% mismatched pair. Everything comes from <project>/tracks/ via the Experiment/project folder.
row=row+1; sec_lbl(lg,row,'CELL  (auto-loaded from the project tracks/ folder)');
row=row+1;
c.status = uilabel(lg,'Text','Not loaded','FontSize',9,...
    'FontColor',[0.4 0.4 0.4],'WordWrap','on');
c.status.Layout.Row = row; c.status.Layout.Column = [1 2];
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
    'Tooltip',['Frame-to-frame LAP search radius you used. Recorded for provenance, and it sets ' ...
    'the floor under the mislinkage flag. The crowding metric has its OWN radius below — the two ' ...
    'answer different questions and were wrongly tied together.'], ...
    'ValueChangedFcn',@(~,~) on_param_change());
c.link_dist.Layout.Row=row; c.link_dist.Layout.Column=2;
row=row+1; lbl2(lg,row,'Gap-close max dist (µm):');
c.gap_dist = uispinner(lg,'Limits',[0.05 20],'Value',1.0,'Step',0.1,'FontSize',9, ...
    'Tooltip','Gap-closing LAP max distance. A single step longer than this can only be a mis-link (used by the jump filter).', ...
    'ValueChangedFcn',@(~,~) on_param_change());
c.gap_dist.Layout.Row=row; c.gap_dist.Layout.Column=2;
row=row+1; lbl2(lg,row,'Max frame gap:');
% Read-only. setnum fills it from tracking.max_gap_frames and NOTHING in this file ever reads it —
% it is pure provenance from Tool 1, so offering a spinner invited the user to change a number that
% could not do anything. The other two look identical but are NOT records: link_dist sets the
% step-flag threshold and gap_dist IS the jump filter, so both stay editable.
c.max_frame_gap = uilabel(lg,'Text','—','FontSize',9,'FontColor',[0.35 0.35 0.35], ...
    'Tooltip','From Tool 1''s tracking.max_gap_frames. Provenance only — nothing here reads it.');
c.max_frame_gap.Layout.Row=row; c.max_frame_gap.Layout.Column=2;

% -- Crowding metric --  how "local density" is measured, before you threshold it
row=row+1; sec_lbl(lg,row,'CROWDING — how density is measured');
row=row+1; lbl2(lg,row,'Density radius (µm):');
c.dens_rad = uispinner(lg,'Limits',[0.1 20],'Value',2.0,'Step',0.25,'FontSize',9, ...
    'Tooltip',['Neighbourhood radius for the crowding count — INDEPENDENT of the linking distance. ' ...
    'At the linking radius the metric had almost no dynamic range (on the reference cell 73% of ' ...
    'tracks scored 0 and the maximum was 2). 2 µm spreads the same cell over 0-8.'], ...
    'ValueChangedFcn',@(~,~) on_param_change());
c.dens_rad.Layout.Row=row; c.dens_rad.Layout.Column=2;
row=row+1; lbl2(lg,row,'Per track use:');
c.dens_stat = uidropdown(lg,'Items',{'mean (time-averaged)','max (worst frame)'}, ...
    'ItemsData',{'mean','max'},'Value','mean','FontSize',9, ...
    'Tooltip',['mean = is this track sitting in a crowded REGION (what you want to avoid); ' ...
    'max = did it ever touch one crowded frame (mislinkage risk). max saturates — on the reference ' ...
    'cell its median is 2 for every track-length class — so mean discriminates far better.'], ...
    'ValueChangedFcn',@(~,~) on_param_change());
c.dens_stat.Layout.Row=row; c.dens_stat.Layout.Column=2;
row=row+1;
c.dens_cloud = uicheckbox(lg,'Text','Count untracked detections too','Value',true,'FontSize',9, ...
    'Tooltip',['Count the WHOLE localization cloud, not just spots in surviving tracks. The ' ...
    'reference cell holds 220,401 detections but only 73,994 in tracks — untick this and two ' ...
    'thirds of what you can see in the field of view stops counting as crowding.'], ...
    'ValueChangedFcn',@(~,~) on_param_change());
c.dens_cloud.Layout.Row=row; c.dens_cloud.Layout.Column=[1 2];
row=row+1;
c.dens_lbl = uilabel(lg,'Text','—','FontSize',8.5,'FontColor',[0.25 0.45 0.25],'WordWrap','on');
c.dens_lbl.Layout.Row=row; c.dens_lbl.Layout.Column=[1 2];

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

% -- Review section — the point of this tab: look at what the filter rejected and overrule it --
row=row+1; sec_lbl(lg,row,'REVIEW  (click a track in Overview, then keep/reject it)');
row=row+1; lbl2(lg,row,'Show:');
c.show_mode = uidropdown(lg,'Items',{'All tracks','Kept only','Rejected only'}, ...
    'ItemsData',{'all','kept','rej'},'Value','all','FontSize',9, ...
    'Tooltip',['Which tracks the Overview draws. "Rejected only" is the review mode: the tracks ' ...
    'the filter threw out, on their own, so you can click each one and decide. The kept ones are ' ...
    'already accepted — you do not need to see them to review.'], ...
    'ValueChangedFcn',@(~,~) do_reshuffle());
c.show_mode.Layout.Row=row; c.show_mode.Layout.Column=2;
row=row+1; lbl2(lg,row,'Max drawn:');
c.max_shown = uispinner(lg,'Limits',[10 2000],'Value',100,'Step',10,...
    'FontSize',9,'ValueChangedFcn',@(~,~) do_reshuffle());
c.max_shown.Layout.Row=row; c.max_shown.Layout.Column=2;
row=row+1;
c.reshuffle = half_btn(lg,row,1,'Reshuffle',[0.85 0.85 0.85],[0 0 0]);
c.reshuffle.ButtonPushedFcn = @(~,~) do_reshuffle();
c.next_rej = half_btn(lg,row,2,'Next rejected ▶',[0.80 0.45 0.10],'white');
c.next_rej.Tooltip = 'Select the next rejected track and centre the detail panel on it — walk the rejects one by one.';
c.next_rej.ButtonPushedFcn = @(~,~) next_rejected();

% The decision button. Big, coloured by what it will DO, and it names the track — this is the
% control the whole tab exists for, so it should not look like a grey utility button.
row=row+1; row=row+1;                                        % two rows tall
c.toggle_btn = uibutton(lg,'Text','Toggle keep/reject','FontSize',12,'FontWeight','bold', ...
    'BackgroundColor',[0.55 0.55 0.58],'FontColor','white','Enable','off', ...
    'Tooltip','Flip the selected track between KEEP and REJECT. Manual decisions survive re-filtering, batch runs and switching cells.', ...
    'ButtonPushedFcn',@(~,~) do_toggle());
c.toggle_btn.Layout.Row=[row-1 row]; c.toggle_btn.Layout.Column=[1 2];
% -- Mislinkage repair. A bad link costs you the WHOLE track today: the jump gate rejects any track
% containing a step over the gap-close distance. Cutting the link instead splits the chain and both
% halves go back through the filters, so the good part survives.
row=row+1; sec_lbl(lg,row,'MISLINKAGE (selected track)');
row=row+1;
lbl2(lg,row,'Flag step ≥ ×median');
c.link_ratio = uispinner(lg,'Limits',[1.5 20],'Value',5,'Step',0.5,'FontSize',9, ...
    'Tooltip',['A link is flagged when its step is this many times the SELECTED track''s own median ' ...
               'step (or longer than the gap-close distance). Relative, because a mislinkage in a ' ...
               'confined track is a 0.8 µm stride among 0.2 µm ones — far below any absolute gate.'], ...
    'ValueChangedFcn',@(~,~) refresh_links());
c.link_ratio.Layout.Row=row; c.link_ratio.Layout.Column=2;
row=row+1;
c.flag_lbl = uilabel(lg,'Text','—','FontSize',8.5,'FontColor',[0.25 0.45 0.25],'WordWrap','on');
c.flag_lbl.Layout.Row=row; c.flag_lbl.Layout.Column=[1 2];

row=row+1;
c.link_prev = half_btn(lg,row,1,'◀ link',[0.30 0.40 0.55],'white');
c.link_prev.Tooltip = 'Step to the previous link of this track. Nothing selected yet → jumps to the worst link.';
c.link_prev.ButtonPushedFcn = @(~,~) link_goto(-1);
c.link_next = half_btn(lg,row,2,'link ▶',[0.30 0.40 0.55],'white');
c.link_next.Tooltip = 'Step to the next link of this track. Nothing selected yet → jumps to the worst link.';
c.link_next.ButtonPushedFcn = @(~,~) link_goto(+1);

row=row+1;
c.link_worst = half_btn(lg,row,1,'▲ Worst',[0.55 0.35 0.10],'white');
c.link_worst.Tooltip = 'Jump straight to this track''s largest step relative to its own median.';
c.link_worst.ButtonPushedFcn = @(~,~) link_goto_worst();
c.link_flag = half_btn(lg,row,2,'⚠ Next flagged',[0.80 0.25 0.10],'white');
c.link_flag.Tooltip = 'Next flagged link WITHIN this track, wrapping around — skips the ordinary ones.';
c.link_flag.ButtonPushedFcn = @(~,~) link_next_susp_in_track();

row=row+1;
c.play_link = half_btn(lg,row,1,'▶ Play link',[0.18 0.60 0.44],'white');
c.play_link.Tooltip = ['Loop the few frames around this link in the raw movie, so you can watch the ' ...
    'spot cross it. A real step keeps one emitter moving; a mislinkage blinks between two.'];
c.play_link.ButtonPushedFcn = @(~,~) play_link();
c.link_pad = uispinner(lg,'Limits',[0 20],'Value',2,'Step',1,'FontSize',9, ...
    'Tooltip','Frames shown either side of the link when looping it.', ...
    'ValueChangedFcn',@(~,~) set_link_pad());
c.link_pad.Layout.Row=row; c.link_pad.Layout.Column=2;
row=row+1;
c.zoom_link = uicheckbox(lg,'Text','Zoom map to the selected link','Value',true,'FontSize',9, ...
    'Tooltip',['Frame the trajectory panel on the link instead of the whole track, so the individual ' ...
               'emitters and their rings are resolvable. Untick to keep the whole track in view.'], ...
    'ValueChangedFcn',@(~,~) refreshTraj());
c.zoom_link.Layout.Row=row; c.zoom_link.Layout.Column=[1 2];

row=row+1;
c.cut_btn = wide_btn(lg,row,'✂ Cut link',[0.70 0.12 0.12],'white');
c.cut_btn.Enable = 'off';
c.cut_btn.Tooltip = 'Cut the link on the cursor. The track splits in two and both halves go back through the filters.';
c.cut_btn.ButtonPushedFcn = @(~,~) cut_current();

row=row+1; row=row+1;
c.link_lbl = uilabel(lg,'Text','Select a track, then ◀ / ▶ to walk its links.','FontSize',8.5, ...
    'WordWrap','on','FontColor',[0.2 0.2 0.2],'VerticalAlignment','top');
c.link_lbl.Layout.Row=[row-1 row]; c.link_lbl.Layout.Column=[1 2];

row=row+1;
c.next_link = half_btn(lg,row,1,'⚠ Next track',[0.60 0.30 0.10],'white');
c.next_link.Tooltip = 'Jump to the next KEPT track that has any flagged link, and land on its worst one.';
c.next_link.ButtonPushedFcn = @(~,~) next_suspicious();
c.undo_cut = half_btn(lg,row,2,'↩ Undo cut',[0.45 0.45 0.50],'white');
c.undo_cut.Tooltip = 'Undo the most recent cut on this cell. Cuts are remembered per cell and survive re-filtering, batch runs and switching cells.';
c.undo_cut.ButtonPushedFcn = @(~,~) undo_cut();

row=row+1; row=row+1; row=row+1;                             % 3 rows so the detail never clips
c.sel_lbl = uilabel(lg,'Text','Click a track in the Overview panel to select it.','FontSize',8.5,...
    'WordWrap','on','FontColor',[0.2 0.2 0.2],'VerticalAlignment','top');
c.sel_lbl.Layout.Row=[row-2 row]; c.sel_lbl.Layout.Column=[1 2];

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

% -- Playback --
row=row+1; sec_lbl(lg,row,'PLAYBACK');
row=row+1; lbl2(lg,row,'FPS:');
c.fps = uispinner(lg,'Limits',[1 60],'Value',15,'Step',1,'FontSize',9, ...
    'Tooltip','Playback rate. Takes effect immediately, including while playing.', ...
    'ValueChangedFcn',@(~,~) retune_playback());   % live: was only read once, at Play
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
% the full-track Play must leave link-loop mode, or it would silently keep looping 5 frames
c.pause_btn = half_btn(lg,row,2,'Pause',[0.91 0.30 0.24],'white');
c.play_btn.ButtonPushedFcn  = @(~,~) play_whole_track();
c.pause_btn.ButtonPushedFcn = @(~,~) do_pause();

% -- Structure overlay (ER / mito) --
row=row+1; sec_lbl(lg,row,'OVERLAY (ER / mito structure)');
row=row+1; lbl2(lg,row,'Overlay FOV (um):');
c.ov_fov = uispinner(lg,'Limits',[1 500],'Value',27.61,'Step',0.5,'FontSize',9,...
    'Tooltip',['Physical width the raw movie and the ER/mito overlay are drawn across. Read from ' ...
               'the movie''s own pixel size when it has one — it must match the track coordinates ' ...
               'or the image sits under the wrong place.'], ...
    'ValueChangedFcn',@(~,~) update_spatial());
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
c.spt_con = uispinner(lg,'Limits',[0.1 1],'Value',1.0,'Step',0.05,'FontSize',9, ...
    'Tooltip',['Brightness about the automatic range. 1.0 is the range ImageJ''s Auto measures over ' ...
               'a sample of the whole stack; lower pulls the white point in and brightens. It used ' ...
               'to scale from zero with no black point, which washed the background to 79% white ' ...
               'and clipped almost every spot.'], ...
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

% The control column declared 60 rows and grew to 70 as controls were added over time. MATLAB does
% not complain: it auto-creates the extra rows as '1x', and in a SCROLLABLE grid a '1x' row collapses
% to ZERO HEIGHT. So rows 61-70 were laid out at h=0 and simply could not be seen — which is why the
% ER colour picker (row 60) was visible and the mito one (row 61) was not, along with the kept and
% excluded colours, the overlay status label, and the entire batch section.
%
% Sizing from the highest row actually used means adding a control can never reintroduce it.
% Note the count is NOT the tell: MATLAB grows RowHeight to match, so numel() already reads 70. It
% is the TYPE that is wrong — the rows it invents are '1x', and '1x' means zero in a scrollable
% grid. Rewrite every row to the fixed pitch the declaration intended.
maxRow = 0;
for ch = lg.Children'
    try, maxRow = max(maxRow, max(ch.Layout.Row)); catch, end
end
maxRow = max(maxRow, numel(lg.RowHeight));
if maxRow > 0, lg.RowHeight = repmat({22}, 1, maxRow); end

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
rg = uigridlayout(rp,[4 1],...
    'RowHeight',{'2x','0.75x','1x','1x'},...
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

% ---- link strip: the selected track as nodes + connections, laid out along TIME ----
% Our tracks are strictly linear chains — spt_track links frame-to-frame with matchpairs (one-to-one)
% and consumes each gap-close start once — so there are no split/merge events and a track is a simple
% path. That is why this is a horizontal strip rather than TrackMate's 2D TrackScheme: with no
% branching, the second dimension would carry nothing. Sharing the time axis with the step plot below
% is what makes it useful — the spike there IS the suspicious edge here.
ax_gr = uiaxes(rg); ax_gr.Layout.Row=2;
ax_gr.YLabel.String='links'; ax_gr.FontSize=8; hold(ax_gr,'on'); box(ax_gr,'on');
ax_gr.YTick=[]; ax_gr.YLim=[-1 1];
ax_gr.XTickLabel={};                     % the step plot directly below carries the shared time axis
disableDefaultInteractivity(ax_gr);      % same reason as ax_tr: interaction modes break in a uifigure
ax_gr.Toolbar.Visible='off';
ax_gr.ButtonDownFcn = @(s,e) on_strip_click(e);

ax_dv2 = uiaxes(rg); ax_dv2.Layout.Row=3;
ax_dv2.XLabel.String='Time (s)'; ax_dv2.YLabel.String='Step (um)';
ax_dv2.FontSize=8; hold(ax_dv2,'on');
ax_dv2.ButtonDownFcn = @(s,e) on_strip_click(e);   % clicking the spike cuts the same edge

ax_in = uiaxes(rg); ax_in.Layout.Row=4;
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

    % ---- activity log + busy feedback -----------------------
    function clog(varargin)
        % Every long or destructive action writes here, so a click always leaves a trace even when
        % the result is "nothing changed". The pane sits outside the scrollable controls.
        if ~isfield(c,'log') || isempty(c.log) || ~isgraphics(c.log), return; end
        c.log.Value = [c.log.Value; {sprintf(varargin{:})}];
        scroll(c.log,'bottom'); drawnow limitrate;
    end

    function setBusy(tf, actor, busyTxt)
        % Amber "working…" on the button that was clicked, the other long-running actions disabled,
        % everything restored afterwards. Same pattern as Tool 1's Track tab.
        for h = [getf_(c,'apply_btn'), getf_(c,'export_btn'), getf_(c,'export_next_btn'), getf_(c,'batch_btn')]
            if isempty(h) || ~isgraphics(h), continue; end
            if tf, h.Enable = 'off'; else, h.Enable = 'on'; end
        end
        if nargin >= 2 && ~isempty(actor) && isgraphics(actor)
            if tf
                actor.UserData = {actor.Text, actor.BackgroundColor, actor.FontColor};
                if nargin < 3 || isempty(busyTxt), busyTxt = '⏳ working…'; end
                actor.Text = busyTxt; actor.BackgroundColor = [0.90 0.58 0.10];
                actor.FontColor = 'white'; actor.Enable = 'on';
            elseif iscell(actor.UserData) && numel(actor.UserData) == 3
                actor.Text = actor.UserData{1}; actor.BackgroundColor = actor.UserData{2};
                actor.FontColor = actor.UserData{3}; actor.UserData = [];
            end
        end
        drawnow;
    end

    function h = getf_(s, f)
        if isfield(s,f), h = s.(f); else, h = gobjects(0); end
    end

    function publish_state()
        % Headless test hook (spt_curate_review_smoke): mirror the decision state onto the host
        % figure after every change. The UI itself never reads this.
        if isempty(fig) || ~isgraphics(fig), return; end
        base = ''; if ~isempty(S.file_list) && S.current_file>=1, base = S.file_list{S.current_file}{3}; end
        nAll = 0; if ~isempty(S.track_metrics), nAll = height(S.track_metrics); end
        setappdata(fig,'tv_state', struct( ...
            'base',base, 'nAll',nAll, 'nKept',numel(S.kept_ids), 'nRej',nAll-numel(S.kept_ids), ...
            'kept',S.kept_ids(:)', 'shown',S.shown_ids(:)', 'nShown',numel(S.shown_ids), ...
            'sel',S.selected_id, 'mkeep',S.manual_keep(:)', 'mrej',S.manual_reject(:)', ...
            'playing',S.playing, 'nCuts',numel(S.cuts), ...
            'frame',S.current_frame, 'playRange',S.playRange, 'linkLoop',S.linkLoop));
        % Link-cut hooks (spt_linkcut_smoke). The spot table is the only place the split is visible
        % before export, and do_cut is what a click on the strip ends up calling — a headless test has
        % no way to click an axes, so it invokes the same entry point the UI does.
        setappdata(fig,'tv_spots', S.spots_t);
        setappdata(fig,'tv_metrics', S.track_metrics);
        setappdata(fig,'tv_cuts',  S.cuts);
        setappdata(fig,'tv_docut', @do_cut);
        setappdata(fig,'tv_links', @link_info);
        setappdata(fig,'tv_select',@select_track);
        setappdata(fig,'tv_nav',   struct('goto',@link_goto,'worst',@link_goto_worst, ...
                                          'flag',@link_next_susp_in_track,'cut',@cut_current, ...
                                          'idx',S.linkIdx));
    end

    function s = hms_(sec)
        if sec < 60, s = sprintf('%.1f s', sec);
        else, s = sprintf('%d m %02.0f s', floor(sec/60), mod(sec,60)); end
    end

    % ---- link cuts, remembered PER CELL ----------------------
    % Same durability contract as the manual keep/reject below: a cut is the user's judgement about
    % the data and must survive a filter re-apply, a cell round trip and a batch run.
    function cuts_store()
        if isempty(S.file_list) || S.current_file < 1, return; end
        k = man_key(S.file_list{S.current_file}{3});
        S.cuts_by_cell(k) = struct('cuts', S.cuts, 'nextId', S.nextFragId);
    end

    function cuts_restore(base)
        k = man_key(base);
        if isKey(S.cuts_by_cell, k)
            r = S.cuts_by_cell(k); S.cuts = r.cuts; S.nextFragId = r.nextId;
        else
            S.cuts = struct('afterSpotId',{},'newId',{},'origId',{}); S.nextFragId = [];
        end
    end

    function apply_cuts()
        if ~ismember('ORIG_TRACK_ID', S.spots_t.Properties.VariableNames), return; end
        S.spots_t = apply_cuts_to(S.spots_t, S.cuts);
        S.spots_t = sortrows(S.spots_t, {'TRACK_ID','FRAME'});
        S.track_metrics = compute_metrics_from_spots(S.spots_t);
    end

    function T = apply_cuts_to(T, cuts)
        % Rebuild TRACK_ID from the ORIGINAL ids plus a cut list. Walk each original chain in frame
        % order and switch to the minted id every time we leave a cut spot; a fragment that is itself
        % cut again simply switches twice, so nested cuts need no special case. An uncut track keeps
        % its original id exactly, which is what lets a manual override on it survive a cut made
        % elsewhere in the cell.
        % Shared by the interactive path and the batch so the two cannot drift apart — the batch
        % re-derives its table from the XML on disk and would otherwise re-introduce the mislinkage.
        if ~ismember('ORIG_TRACK_ID', T.Properties.VariableNames)
            T.ORIG_TRACK_ID = T.TRACK_ID;         % batch tables arrive with only the tracker's ids
        end
        if isempty(cuts), T.TRACK_ID = T.ORIG_TRACK_ID; return; end
        T = sortrows(T, {'ORIG_TRACK_ID','FRAME'});
        cutAfter = [cuts.afterSpotId]; cutNew = [cuts.newId];
        % Read the chain boundary from ORIG (untouched) and write into a SEPARATE vector. Testing
        % out(i)~=out(i-1) instead would compare against a value this loop had already overwritten:
        % one spot past a cut the two look equal, and one spot after that the original id reappears
        % and resets cur — so exactly one localization moved to the new fragment.
        orig = T.ORIG_TRACK_ID; sid = T.SPOT_ID;
        out = orig; cur = orig(1);
        for i = 1:numel(orig)
            if i > 1 && orig(i) ~= orig(i-1), cur = orig(i); end  % new original chain
            out(i) = cur;
            j = find(cutAfter == sid(i), 1);
            if ~isempty(j), cur = cutNew(j); end                  % the link LEAVING this spot is cut
        end
        T.TRACK_ID = out;
    end

    function ok = do_cut(afterSpotId)
        % Sever the link leaving afterSpotId. Both halves go back through the filters, per the design:
        % a fragment that no longer clears min length is not silently privileged just because it came
        % from a cut. Any manual keep/reject on the track being cut is dropped — it was a judgement
        % about a chain that no longer exists.
        ok = false;
        if ~S.loaded || isempty(afterSpotId) || isnan(afterSpotId), return; end
        row = find(S.spots_t.SPOT_ID == afterSpotId, 1);
        if isempty(row), clog('CUT: spot %g is not in this cell.', afterSpotId); return; end
        tid = S.spots_t.TRACK_ID(row);
        chain = sortrows(S.spots_t(S.spots_t.TRACK_ID==tid,:), 'FRAME');
        if chain.SPOT_ID(end) == afterSpotId
            clog('CUT: that is the last spot of track %g — no link leaves it.', tid); return;
        end
        if any([S.cuts.afterSpotId] == afterSpotId)
            clog('CUT: that link is already cut.'); return;
        end
        if isempty(S.nextFragId)
            S.nextFragId = max(S.spots_t.ORIG_TRACK_ID) + 1;   % mint above every original id
        end
        newId = S.nextFragId; S.nextFragId = S.nextFragId + 1;
        origId = S.spots_t.ORIG_TRACK_ID(row);
        S.cuts(end+1) = struct('afterSpotId',afterSpotId,'newId',newId,'origId',origId);
        % the chain the user judged is gone; do not carry its verdict onto either half
        S.manual_keep   = setdiff(S.manual_keep,   tid);
        S.manual_reject = setdiff(S.manual_reject, tid);
        apply_cuts();
        S.linkIdx = []; clear_link_playback();   % the chain it indexed no longer exists
        nHead = sum(S.spots_t.TRACK_ID==tid); nTail = sum(S.spots_t.TRACK_ID==newId);
        clog('✂ CUT track %g after spot %g → %g (%d locs) + %g (%d locs)%s', ...
            tid, afterSpotId, tid, nHead, newId, nTail, ...
            tern_(origId~=tid, sprintf(' [from original %g]', origId), ''));
        cuts_store(); man_store();
        do_apply_filter();                  % both halves re-enter the filters, per the design
        S.selected_id = tid; select_track(tid);
        ok = true;
    end

    function undo_cut()
        if isempty(S.cuts), clog('UNDO: no cuts on this cell.'); return; end
        last = S.cuts(end); S.cuts(end) = [];
        apply_cuts();
        S.linkIdx = []; clear_link_playback();   % the chain it indexed has just changed length
        clog('↩ UNDO cut on track %g (spot %g) — %d cut(s) left on this cell.', ...
            last.origId, last.afterSpotId, numel(S.cuts));
        cuts_store();
        do_apply_filter();
        S.selected_id = last.origId; select_track(last.origId);
    end

    % ---- manual keep/reject, remembered PER CELL -------------
    % These decisions are the user's own judgement and must outlive everything automatic: a filter
    % re-apply, a batch run over every cell, and navigating away to another cell and back. They were
    % previously wiped on every load_file and ignored by the batch entirely.
    function key = man_key(base)
        key = char(base);
    end

    function man_store()
        if isempty(S.file_list) || S.current_file < 1, return; end
        k = man_key(S.file_list{S.current_file}{3});
        S.manual_by_cell(k) = struct('keep', S.manual_keep(:)', 'reject', S.manual_reject(:)');
    end

    function man_restore(base)
        k = man_key(base);
        if isKey(S.manual_by_cell, k)
            m = S.manual_by_cell(k);
            S.manual_keep = m.keep(:); S.manual_reject = m.reject(:);
        else
            S.manual_keep = []; S.manual_reject = [];
        end
    end

    % ---- Core load + compute --------------------------------
    function load_file(idx)
        do_pause();
        man_store();                 % keep the outgoing cell's decisions before switching
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
        % The WHOLE localization cloud, kept for the crowding metric. Only a third of these end up in
        % surviving tracks, but an untracked blink still crowds the field and still confuses the
        % linker — counting only tracked spots is what made the density filter blind.
        ok_ = isfinite(spots_j.FRAME) & isfinite(spots_j.X_um) & isfinite(spots_j.Y_um);
        S.cloud = [spots_j.FRAME(ok_), spots_j.X_um(ok_), spots_j.Y_um(ok_)];

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
        % Keep the XML's own ids as ORIG_TRACK_ID. Everything downstream reads TRACK_ID, which is a
        % DERIVED column: original id for an uncut chain, a minted id for each fragment after a cut.
        spots_t.ORIG_TRACK_ID = spots_t.TRACK_ID;
        S.spots_t       = spots_t;
        cuts_restore(base_name);  % this cell's own link cuts, if it has been edited before
        apply_cuts();             % rebuild TRACK_ID + metrics from ORIG_TRACK_ID + those cuts
        tm              = S.track_metrics;
        track_ids       = tm.TRACK_ID;
        n_t             = height(tm);
        S.xml_doc       = xdoc;
        S.kept_ids      = track_ids;
        man_restore(base_name);   % this cell's own manual decisions, if it has been reviewed before
        if ~isempty(S.cuts)
            clog('   %d link cut(s) restored for this cell.', numel(S.cuts));
        end
        S.kept_ids      = union(setdiff(S.kept_ids, S.manual_reject), S.manual_keep);
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
        c.status.FontColor = [0.4 0.4 0.4];
        nman = numel(S.manual_keep) + numel(S.manual_reject);
        clog('LOAD %s · %d tracks · %d spots%s', base_name, n_t, height(spots_t), ...
            tern_(nman>0, sprintf(' · restored %d manual override%s', nman, tern_(nman==1,'','s')), ''));

        update_histograms();
        updateFilterLabels();
        refresh_thresh_labels();   % show each percentile's threshold value for THIS file
        refresh_toggle_btn();
        publish_state();
        do_reshuffle();
    end

    % ---- Metric computation (shared: load + batch + param change) -----------
    function R = metric_R()
        % Crowding radius, INDEPENDENT of the linking distance. It used to be the linking distance,
        % which conflated two different questions: how far the tracker may link (an algorithm limit,
        % 0.8 µm here) versus how large a neighbourhood counts as "crowded" (a biology/optics
        % question). At the linking radius the metric had no dynamic range — see
        % compute_metrics_from_spots.
        R = DENSITY_RADIUS;
        if isfield(c,'dens_rad') && isgraphics(c.dens_rad), R = c.dens_rad.Value; end
    end

    function st = density_stat()
        st = 'mean';
        if isfield(c,'dens_stat') && isgraphics(c.dens_stat), st = c.dens_stat.Value; end
    end

    function tf = density_use_cloud()
        tf = true;
        if isfield(c,'dens_cloud') && isgraphics(c.dens_cloud), tf = c.dens_cloud.Value; end
    end

    function [CF, CX, CY] = density_source(spots_t, cloud)
        % Which detections count as neighbours. The whole cloud by default: an untracked blink still
        % crowds the field and still confuses the linker, and it is what you actually see on screen.
        % The cloud is passed in rather than read from S, because the batch measures cells that are
        % NOT the one currently open — reading S.cloud there would score every cell in the run
        % against the open cell's field.
        if density_use_cloud() && ~isempty(cloud)
            CF = cloud(:,1); CX = cloud(:,2); CY = cloud(:,3);
        else
            CF = spots_t.FRAME; CX = spots_t.X_um; CY = spots_t.Y_um;
        end
    end

    function d = local_density(tf, tx, ty, cf, cx, cy, R)
        % Neighbours within R, in the same frame, for every spot in (tf,tx,ty), counted against the
        % cloud (cf,cx,cy). Both sides are bucketed by frame once and walked together — the previous
        % version ran find(FRAME==f) inside a loop over frames, which is O(frames x spots) and on this
        % cell alone was 5,981 x 73,994 element comparisons before any distance was computed.
        d = zeros(numel(tf),1);
        if isempty(tf) || isempty(cf), return; end
        [cfs, oc] = sort(cf(:)); cxs = cx(oc); cys = cy(oc);
        cs = [1; find(diff(cfs))+1]; ce = [cs(2:end)-1; numel(cfs)]; cfr = cfs(cs);
        [tfs, ot] = sort(tf(:)); txs = tx(ot); tys = ty(ot);
        ts = [1; find(diff(tfs))+1]; te = [ts(2:end)-1; numel(tfs)]; tfr = tfs(ts);
        [hit, loc] = ismember(tfr, cfr);
        ds = zeros(numel(tfs),1);
        for g = 1:numel(tfr)
            if ~hit(g), continue; end
            ti = ts(g):te(g); ci = cs(loc(g)):ce(loc(g));
            if numel(ci) < 2, continue; end
            D = pdist2([txs(ti) tys(ti)], [cxs(ci) cys(ci)]);
            % every tracked spot is itself in the cloud, so one of those distances is its own zero
            ds(ti) = max(sum(D <= R, 2) - 1, 0);
        end
        d(ot) = ds;
    end

    function tm = compute_metrics_from_spots(spots_t, cloud)
        if nargin < 2, cloud = S.cloud; end        % interactive path: the open cell's own cloud
        % Per-spot local density: how many OTHER detections share this spot's frame within radius R.
        %
        % Two things here used to make this metric nearly useless, both measured on the WithER cell:
        %   · R was the LINKING radius (0.8 µm). At that radius 73% of tracks had a max density of 0
        %     and the largest value in the whole cell was 2 — the filter could only ever say 0, 1 or 2,
        %     which is why one slider position kept 838 tracks and the next kept 835. R is now its own
        %     spinner, defaulting to 2 µm, where the same cell spreads over 0-8.
        %   · Only TRACKED spots were counted. The cell holds 220,401 detections but only 73,994 in
        %     surviving tracks, so two thirds of what you can see in the field of view — every blink,
        %     every spot too short-lived to track — was invisible to the crowding measure. It now
        %     counts the whole localization cloud by default.
        %
        % Per track the statistic is selectable, because MAX and MEAN answer different questions:
        %   max  — the worst single frame. "Did this track ever risk a mislinkage?" Saturates: on the
        %          reference cell the median max is 2 for every track-length class, so it separates
        %          poorly.
        %   mean — time-averaged over the track's own lifetime. "Is this track sitting in a crowded
        %          REGION?" This is the one that discriminates (median 0.62 / 0.54 / 0.36 across
        %          short / mid / long tracks) and the one to use to avoid crowded regions.
        % Plus displacement variance, the max single-step jump, and confinement.
        R = metric_R();
        [CF, CX, CY] = density_source(spots_t, cloud);
        dens_v = local_density(spots_t.FRAME, spots_t.X_um, spots_t.Y_um, CF, CX, CY, R);
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
            if strcmp(density_stat(),'max')
                mean_local_density(ti) = max(r.LOCAL_DENSITY,[],'omitnan');   % worst single frame
            else
                mean_local_density(ti) = mean(r.LOCAL_DENSITY,'omitnan');     % time-averaged crowding
            end
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
        % a crowding or tracking parameter changed -> re-measure and rescale the threshold to match
        if ~S.loaded || isempty(S.spots_t), return; end
        S.track_metrics = compute_metrics_from_spots(S.spots_t);
        tm = S.track_metrics;
        d  = tm.mean_local_density;
        dn = max(d);
        if dn>0
            % 'mean' produces fractional densities, so the old integer-ish +1 headroom is not enough
            % resolution; give the slider a little padding and keep the current value inside it.
            hi = dn*1.05 + 0.01;
            c.max_dn.Limits=[0 hi]; c.max_dn.Value=min(c.max_dn.Value,hi);
        end
        report_density_spread(d);
        update_histograms(); preview_filter(); refresh_thresh_labels();
        publish_state();     % the metrics table just changed; observers must see the new values
    end

    function report_density_spread(d)
        % Say plainly whether the metric can discriminate at these settings. A metric where most
        % tracks score zero cannot separate anything, and that was the state this filter shipped in.
        if ~isfield(c,'dens_lbl') || ~isgraphics(c.dens_lbl), return; end
        d = d(isfinite(d));
        if isempty(d), c.dens_lbl.Text = '—'; return; end
        z = 100*mean(d<=0); q = quantile(d,[0.5 0.9]);
        c.dens_lbl.Text = sprintf('%s within %.2f µm: median %.2f · p90 %.2f · max %.2f · %.0f%% at zero', ...
            tern_(strcmp(density_stat(),'max'),'worst frame','time-avg'), metric_R(), q(1), q(2), max(d), z);
        if z > 50
            c.dens_lbl.FontColor = [0.75 0.35 0.05];   % cannot discriminate: most tracks score nothing
        else
            c.dens_lbl.FontColor = [0.25 0.45 0.25];
        end
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

    function retune_playback()
        % FPS is live: if a track is playing, restart the timer at the new period rather than
        % waiting for the next Play (the period was previously read once, at Play time).
        if S.playing, do_pause(); do_play(); end
    end

    function next_rejected()
        % Walk the rejected tracks one at a time — the review loop this tab exists for.
        if ~S.loaded, return; end
        rej = setdiff(S.track_metrics.TRACK_ID, S.kept_ids);
        if isempty(rej)
            c.sel_lbl.Text = 'Nothing is rejected at the current thresholds.';
            clog('Review: nothing rejected at the current thresholds.'); return;
        end
        if isempty(S.selected_id), nxt = rej(1);
        else
            after = rej(rej > S.selected_id);
            if isempty(after), nxt = rej(1); else, nxt = after(1); end
        end
        % make sure it is drawn, then select it
        if ~ismember(nxt, S.shown_ids), S.shown_ids = [S.shown_ids(:); nxt]; end
        select_track(nxt);
        clog('Review: rejected track %d  (%d of %d rejected)', nxt, find(rej==nxt,1), numel(rej));
    end

    function refresh_toggle_btn()
        % The decision button states what it will DO to the selected track, and is coloured for it.
        if ~isfield(c,'toggle_btn') || ~isgraphics(c.toggle_btn), return; end
        if ~S.loaded || isempty(S.selected_id)
            c.toggle_btn.Text = 'Toggle keep/reject';
            c.toggle_btn.BackgroundColor = [0.55 0.55 0.58];
            c.toggle_btn.Enable = 'off'; return;
        end
        c.toggle_btn.Enable = 'on';
        if ismember(S.selected_id, S.kept_ids)
            c.toggle_btn.Text = sprintf('✖  REJECT track %d', S.selected_id);
            c.toggle_btn.BackgroundColor = [0.80 0.22 0.18];
        else
            c.toggle_btn.Text = sprintf('✔  KEEP track %d', S.selected_id);
            c.toggle_btn.BackgroundColor = [0.16 0.55 0.28];
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

    function tf = same_file_(a, b)
        % Would writing to `a` destroy `b`? Compares the two paths as the filesystem sees them, so a
        % relative out-dir, a trailing slash or a symlinked tracks/ folder cannot slip a write past
        % the check. Used to refuse any export that would land on the file it just read.
        tf = false;
        if isempty(a) || isempty(b), return; end
        tf = strcmp(canon_(a), canon_(b));
    end

    function p = canon_(p)
        % Resolve to an absolute, symlink-free path. The file need not exist yet (the output usually
        % does not), so resolve the FOLDER — which does — and re-attach the name.
        [d,n,e] = fileparts(char(p));
        if isempty(d), d = pwd; end
        try
            r = char(java.io.File(d).getCanonicalPath());
            if ~isempty(r), d = r; end
        catch
            % no JVM (-nojvm / headless): fall back to the un-resolved absolute path
            if ~isAbsolute_(d), d = fullfile(pwd, d); end
        end
        p = fullfile(d, [n e]);
    end

    function tf = isAbsolute_(d)
        tf = startsWith(d, filesep) || ~isempty(regexp(d, '^[A-Za-z]:[\\/]', 'once'));
    end

    function do_apply_filter()
        if ~S.loaded
            clog('APPLY: nothing loaded — nothing to do.'); return
        end
        setBusy(true, c.apply_btn, '⏳ applying…');
        aGuard = onCleanup(@() setBusy(false, c.apply_btn)); %#ok<NASGU>
        prev_kept = S.kept_ids;
        % filter from the sliders, THEN re-apply the user's manual keep/reject on
        % top so hand overrides survive a filter re-apply (filter + manual coexist).
        S.kept_ids = filter_ids();
        S.kept_ids = union(setdiff(S.kept_ids, S.manual_reject), S.manual_keep);
        n_k=numel(S.kept_ids); n_t=height(S.track_metrics);
        nov = numel(S.manual_keep)+numel(S.manual_reject);
        refresh_links();     % the kept set changed, so the flagged workload has too
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
        clog('APPLY: %d kept / %d rejected of %d  ·  disp var <= %.4f · density <= %.0f%s%s', ...
            n_k, n_t-n_k, n_t, c.max_dv.Value, c.max_dn.Value, ...
            tern_(isfield(c,'reject_jumps') && isgraphics(c.reject_jumps) && c.reject_jumps.Value, ...
                  sprintf(' · jump > %.3g µm', c.gap_dist.Value), ''), ...
            tern_(nov>0, sprintf('  (%d manual override%s kept)', nov, tern_(nov==1,'','s')), ''));
        man_store();
        refresh_toggle_btn();
        publish_state();
        do_reshuffle();
    end

    % ---- Spatial overview -----------------------------------
    function do_reshuffle()
        if ~S.loaded, return, end
        rng(S.resample_seed); S.resample_seed=S.resample_seed+1;
        all_ids = S.track_metrics.TRACK_ID;
        switch c.show_mode.Value
            case 'kept', pool = S.kept_ids;
            case 'rej',  pool = setdiff(all_ids, S.kept_ids);   % review mode: only what was thrown out
            otherwise,   pool = all_ids;
        end
        if isempty(pool)
            S.shown_ids = zeros(0,1); update_spatial();
            if strcmp(c.show_mode.Value,'rej'), clog('Review: nothing rejected at the current thresholds.'); end
            return;
        end
        n_show = min(c.max_shown.Value, numel(pool));
        idx3   = randperm(numel(pool),n_show);
        S.shown_ids = pool(idx3);
        if ~isempty(S.selected_id) && ~ismember(S.selected_id,S.shown_ids)
            S.shown_ids=[S.shown_ids;S.selected_id];
        end
        publish_state();
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
        local_set_record('max_frame_gap', local_settings_num(txt, 'tracking.max_gap_frames'));
    end

    function local_set_record(fld, val)
        % A provenance field is a LABEL, so it takes .Text, not .Value. Shows an em dash when Tool 1
        % wrote no settings file, rather than a stale number from the previous cell.
        if ~isfield(c,fld) || ~isgraphics(c.(fld)), return; end
        if isnan(val), c.(fld).Text = '—'; else, c.(fld).Text = sprintf('%g', val); end
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
        clear_overlay('er'); clear_overlay('mito'); clear_overlay('spt'); S.spt_hi=[]; S.spt_lo=[];
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
                % DISPLAY RANGE. This was prctile(frame 1, 99.9) with the black point hardwired to
                % zero, so the camera offset (~350 counts here) rendered at 79% white and, at the
                % shipped contrast of 0.5, 97.6% of every spot the tracker detected clipped to pure
                % white — the PSF had no structure left, which is the one thing you zoom in to judge.
                % Frame 1 is also the pre-bleach frame, 1.55x brighter than the stack median, and its
                % value was reused for all 5703 frames.
                %
                % ImageJ's Auto over a sample of the whole stack gives a real black point and holds
                % one range across playback. Same helper Tool 1 uses.
                S.spt_lo = [];
                if exist('spt_stack_range','file')==2 && exist('spt_ij_auto','file')==2
                    try
                        rs = spt_stack_range(ov.spt, 12);
                        if ~isempty(rs.sample)
                            [S.spt_lo, S.spt_hi] = spt_ij_auto(rs.sample, 5000);
                        end
                    catch
                    end
                end
                if isempty(S.spt_lo) && ~isempty(S.spt_img)      % fallback: the old rule, better than nothing
                    v=double(S.spt_img(:)); S.spt_lo=0; S.spt_hi=prctile(v(isfinite(v)),99.9);
                    if ~(S.spt_hi>0), S.spt_hi=max(v); end
                end
                % FIELD OF VIEW. c.ov_fov shipped as a hardcoded 27.61 um — the OLD dataset's field
                % of view — and nothing ever wrote it. On a 128 px x 0.16 um/px movie that draws the
                % raw frame and the ER/mito overlay 1.35x too large, so the emitter ring sits on
                % background several microns from the molecule. That is a wrong-pixels bug, not a
                % cosmetic one, and it is almost certainly the "error somewhere" behind the contrast
                % complaint. Read the pixel size off the movie and size the image to it.
                %   XData spans CENTRES of the first and last column, and the coordinate convention
                %   here is X_um = (0-based col) * pxUm, so the far edge is (W-1)*pxUm, not W*pxUm.
                if exist('spt_tiff_calib','file')==2 && isgraphics(c.ov_fov)
                    try
                        cal = spt_tiff_calib(ov.spt);
                        if isfinite(cal.pixUm) && cal.pixUm > 0 && ~isempty(S.spt_img)
                            W = size(S.spt_img,2);
                            fovUm = (W-1) * cal.pixUm;
                            if fovUm >= c.ov_fov.Limits(1) && fovUm <= c.ov_fov.Limits(2)
                                c.ov_fov.Value = fovUm;
                            end
                        end
                    catch
                    end
                end
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
        select_track(tm.TRACK_ID(mi));
    end

    function select_track(tid)
        % One selection path for both the click and "Next rejected", so the detail panel, the
        % decision button and the label can never disagree about what is selected.
        if ~S.loaded, return; end
        % Moving to a different track invalidates the link cursor: index 12 of the old track's list
        % names a different link here, and cutting it would sever a link the user never looked at.
        if isempty(S.selected_id) || ~isequal(S.selected_id, tid)
            S.linkIdx = []; clear_link_playback();
        end
        S.selected_id = tid;
        tm_sel = S.track_metrics(S.track_metrics.TRACK_ID==tid,:);
        if isempty(tm_sel), return; end
        % Re-selecting the SAME track (the KEEP/REJECT button does exactly this) must not throw the
        % movie back to the track's start while a link is under inspection — that is what stranded
        % playback outside its own loop window.
        if isempty(S.linkIdx), S.current_frame = tm_sel.frame_start; end
        kept = ismember(tid, S.kept_ids);
        st = 'KEEP'; if ~kept, st = 'REJECT'; end
        why = '';
        if ismember(tid, S.manual_keep),   why = '  ← your manual KEEP';
        elseif ismember(tid, S.manual_reject), why = '  ← your manual REJECT';
        elseif ~kept
            % name which gate actually rejected it, so the decision is informed
            r = {};
            if ~isnan(tm_sel.disp_variance) && tm_sel.disp_variance > c.max_dv.Value, r{end+1} = 'disp var'; end
            if ~isnan(tm_sel.mean_local_density) && tm_sel.mean_local_density > c.max_dn.Value, r{end+1} = 'density'; end
            if isfield(c,'reject_jumps') && isgraphics(c.reject_jumps) && c.reject_jumps.Value ...
                    && ismember('max_step_um',tm_sel.Properties.VariableNames) ...
                    && ~isnan(tm_sel.max_step_um) && tm_sel.max_step_um > c.gap_dist.Value, r{end+1} = 'jump'; end
            if ~isempty(r), why = ['  ← rejected by ' strjoin(r,' + ')]; end
        end
        c.sel_lbl.Text = sprintf(['Track %d  [%s]%s\n' ...
            'spots %d · frames %d–%d\n' ...
            'disp var %.4f  (max %.4f)\n' ...
            'max density %.0f  (max %.0f)'], ...
            tid, st, why, tm_sel.n_spots, tm_sel.frame_start, tm_sel.frame_end, ...
            tm_sel.disp_variance, c.max_dv.Value, tm_sel.mean_local_density, c.max_dn.Value);
        refresh_toggle_btn();
        publish_state();
        update_spatial();
        update_trajectory(S.current_frame);
        update_disp_plot();
        update_link_strip();     % after the step plot: it locks both time axes together
        update_intensity_plot();
        % A cursor from the previously selected track indexes a different link list — drop it, and
        % leave the cut button disabled until the user picks a link on THIS track.
        if isempty(S.linkIdx)
            c.cut_btn.Enable = 'off'; c.cut_btn.Text = '✂ Cut link';
            L = link_info(tid);
            if isempty(L.step)
                c.link_lbl.Text = 'This track is too short to have links.';
            else
                c.link_lbl.Text = sprintf(['%d links · %d flagged · median step %.3f µm\n' ...
                    '◀ / ▶ to walk them, ▲ Worst for the biggest outlier.'], ...
                    numel(L.step), sum(L.susp), L.med);
            end
            c.link_lbl.FontColor = [0.2 0.2 0.2];
        end
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
        % With a link selected, frame the LINK rather than the whole track. At whole-track zoom a
        % 0.9 µm step inside a 3 µm track is a few pixels wide and the emitters are indistinguishable
        % — which is the whole question. Zoomed in you can see whether one spot moved or the tracker
        % switched to a different one that was sitting there all along.
        % ...but not while the whole track is playing: the molecule leaves a link-sized box within a
        % couple of frames, and the panel then shows an empty crop for the rest of the sweep.
        wholeTrackPlaying = S.playing && ~S.linkLoop;
        if zoom_to_link() && isfield(S,'linkIdx') && ~isempty(S.linkIdx) && ~wholeTrackPlaying
            Lz = link_info(S.selected_id);
            if ~isempty(Lz.step) && S.linkIdx>=1 && S.linkIdx<=numel(Lz.step)
                kz = S.linkIdx;
                zx = [Lz.x0(kz) Lz.x1(kz)]; zy = [Lz.y0(kz) Lz.y1(kz)];
                zpad = max([ring*2.5, er*6, 0.35*hypot(diff(zx),diff(zy))]);
                zxl = [min(zx)-zpad, max(zx)+zpad];
                zyl = [min(zy)-zpad, max(zy)+zpad];
                % Only adopt it if it actually narrows the view. zpad is unconditionally larger than
                % the whole-track pad on the same two spinner values, so on a compact track "zoom to
                % link" would otherwise zoom OUT.
                if diff(zxl) < diff(xl) || diff(zyl) < diff(yl), xl = zxl; yl = zyl; end
            end
        end

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

        % The link on the cursor, drawn IN SPACE. This is the panel that actually answers the
        % question: a genuine mislinkage looks like one long stride bridging two separate clouds,
        % and no amount of staring at a step-vs-time trace shows you that.
        cutTxt = '';
        if isfield(S,'linkIdx') && ~isempty(S.linkIdx)
            Lc = link_info(S.selected_id);
            if ~isempty(Lc.step) && S.linkIdx>=1 && S.linkIdx<=numel(Lc.step)
                k = S.linkIdx;
                plot(ax_tr,[Lc.x0(k) Lc.x1(k)],[Lc.y0(k) Lc.y1(k)],'-', ...
                    'Color',[0.90 0.10 0.10],'LineWidth',2.6,'HitTest','off');
                plot(ax_tr,[Lc.x0(k) Lc.x1(k)],[Lc.y0(k) Lc.y1(k)],'o', ...
                    'MarkerSize',8,'LineWidth',1.6,'MarkerEdgeColor',[0.90 0.10 0.10], ...
                    'MarkerFaceColor','none','HitTest','off');
                cutTxt = sprintf('   link %d/%d: %.2f µm (%.1f×)', k, numel(Lc.step), Lc.step(k), Lc.ratio(k));
            end
        end

        axis(ax_tr,'equal');          % keep circles round (X and Y both in um)
        xlim(ax_tr,xl); ylim(ax_tr,yl);
        title(ax_tr,sprintf('Track %d  t=%.3fs  f=%d   [emitter r=%.2f, ring=%.2f um]%s',...
            S.selected_id,f*S.frame_interval,f,er,ring,cutTxt),'FontSize',9);
        drawnow limitrate;
    end

    function draw_raw_spt(ax, frame)
        % Raw SPT movie frame as a grayscale background spanning the FOV; the axis limits crop it to the
        % track. Drawn at the very bottom so ER/mito + rings + trajectory sit on top. Plays per frame.
        if ~(isfield(c,'spt_chk') && isgraphics(c.spt_chk) && c.spt_chk.Value), return; end
        if isempty(S.spt_path) || S.spt_nfr<1, return; end
        img = overlayImage('spt', frame); if isempty(img), return; end
        % Two-point range, black AND white. The old rule divided by a white point with black pinned
        % to zero, which cannot represent a camera offset at all.
        lo = 0; if isfield(S,'spt_lo') && ~isempty(S.spt_lo), lo = S.spt_lo; end
        hi = S.spt_hi; if isempty(hi) || ~(hi>lo), hi = max(double(img(:))); if ~(hi>lo), hi = lo+1; end, end
        % The control now BRIGHTENS about the auto range instead of scaling from zero: 1.0 is the
        % measured range, lower pulls the white point in. Its old meaning would silently re-crush the
        % image the auto range just fixed.
        con = 1.0; if isfield(c,'spt_con') && isgraphics(c.spt_con), con=c.spt_con.Value; end
        w = lo + max(hi-lo,eps)*max(con,1e-3);
        g = min(max((double(img)-lo)/max(w-lo,eps),0),1);
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

    function update_link_strip()
        % The selected chain as nodes + connections along time. Every edge is one link the tracker
        % made; its colour is the step it represents, so the mislinkage is the hot segment. A link
        % that spans a frame gap is drawn dashed — gap-closed links are structurally the likeliest
        % mislinkages, and that is the one thing the step plot below cannot show you.
        cla(ax_gr);
        S.strip = struct('spotId',[],'t0',[],'t1',[],'step',[],'gap',[]);
        if ~S.loaded || isempty(S.selected_id), title(ax_gr,''); return; end
        L = link_info(S.selected_id);
        if isempty(L.step)
            title(ax_gr,sprintf('track %g — too short to have links', S.selected_id),'FontSize',8);
            return;
        end
        n = numel(L.step);
        S.strip = struct('spotId',L.spotId,'t0',L.t0,'t1',L.t1,'step',L.step,'gap',L.gap);
        % Height carries the RATIO to this track's median step, so an outlier stands up out of the
        % baseline instead of hiding in a flat row of identical dots. Clipped at 6x: past that the
        % exact value stops mattering and the tall ones would flatten everything else.
        h = min(L.ratio, 6) / 6;
        for i = 1:n
            if L.susp(i), col = [0.85 0.12 0.12]; lw = 2.2;
            else,         col = [0.35 0.55 0.75]; lw = 1.2; end
            plot(ax_gr, [L.t0(i) L.t1(i)], [0 0], '-', 'Color',[0.55 0.60 0.66], ...
                'LineWidth', 1.0, 'LineStyle', tern_(L.gap(i),'--','-'), ...
                'HitTest','off','PickableParts','none');
            plot(ax_gr, [1 1]*(L.t0(i)+L.t1(i))/2, [0 h(i)], '-', 'Color',col, ...
                'LineWidth',lw,'HitTest','off','PickableParts','none');
        end
        plot(ax_gr, [L.t0(1); L.t1], zeros(n+1,1), 'o', 'MarkerSize',2.5, ...
            'MarkerFaceColor',[0.15 0.20 0.26],'MarkerEdgeColor','none', ...
            'HitTest','off','PickableParts','none');
        yline(ax_gr, min(ratio_thr(),6)/6, ':', 'Color',[0.85 0.12 0.12], 'LineWidth',0.8);
        % the cursor: a wide translucent band, so it reads at a glance on a 58-link track
        if isfield(S,'linkIdx') && ~isempty(S.linkIdx) && S.linkIdx>=1 && S.linkIdx<=n
            k = S.linkIdx;
            patch(ax_gr, [L.t0(k) L.t1(k) L.t1(k) L.t0(k)], [-1 -1 1 1], [1 0.85 0.2], ...
                'FaceAlpha',0.45,'EdgeColor',[0.85 0.55 0],'LineWidth',1.2, ...
                'HitTest','off','PickableParts','none');
        end
        ax_gr.YLim = [-0.25 1.15];
        nHot = sum(L.susp); nGap = sum(L.gap);
        title(ax_gr, sprintf('track %g · %d links · %d flagged · %d gap-closed   (bar = × median step)', ...
            S.selected_id, n, nHot, nGap), 'FontSize',8);
        xl = [min(L.t0) max(L.t1)]; if diff(xl)<=0, xl = xl + [-1 1]*0.5; end
        pad = 0.02*diff(xl);
        ax_gr.XLim = xl + [-pad pad]; ax_dv2.XLim = ax_gr.XLim;   % the two time axes stay in step
    end

    function thr = suspicious_thr()
        % Absolute ceiling: a step longer than the gap-close distance is a link the tracker was never
        % allowed to make in one hop. Kept, but it is NOT the main detector — see link_info.
        thr = 1.0;
        if isfield(c,'gap_dist') && isgraphics(c.gap_dist), thr = c.gap_dist.Value; end
    end

    function L = link_info(tid)
        % Every link of one track, with the numbers needed to judge and to navigate it.
        %
        % The absolute gap-close gate alone is a poor mislinkage detector, and the WithER cell shows
        % why: its steps run 0.2–0.8 µm against a 1.40 µm gate, so a track that visibly joins two
        % separate clusters is never flagged. What marks a mislinkage is that the step is an OUTLIER
        % FOR THIS TRACK — a molecule diffusing with a 0.2 µm median step does not take one 0.8 µm
        % stride. So the primary test is the ratio to this track's own median step, with a small
        % absolute floor so that a nearly stationary track (median ≈ localization noise) does not
        % flag every jitter as a 3× outlier.
        L = struct('spotId',[],'t0',[],'t1',[],'step',[],'ratio',[],'gap',[],'susp',[], ...
                   'x0',[],'y0',[],'x1',[],'y1',[],'med',0);
        if ~S.loaded || isempty(tid), return; end
        sel = sortrows(S.spots_t(S.spots_t.TRACK_ID==tid,:),'FRAME');
        if height(sel) < 2, return; end
        d  = sqrt(diff(sel.X_um).^2 + diff(sel.Y_um).^2);
        med = median(d); if ~(med>0), med = eps; end
        L.spotId = sel.SPOT_ID(1:end-1);
        L.t0 = sel.FRAME(1:end-1)*S.frame_interval;  L.t1 = sel.FRAME(2:end)*S.frame_interval;
        L.x0 = sel.X_um(1:end-1); L.y0 = sel.Y_um(1:end-1);
        L.x1 = sel.X_um(2:end);   L.y1 = sel.Y_um(2:end);
        L.step = d; L.ratio = d/med; L.gap = diff(sel.FRAME) > 1; L.med = med;
        L.susp = (d > suspicious_thr()) | (L.ratio >= ratio_thr() & d >= step_floor());
    end

    function r = ratio_thr()
        r = 5;
        if isfield(c,'link_ratio') && isgraphics(c.link_ratio), r = c.link_ratio.Value; end
    end

    function f = step_floor()
        % Absolute floor under the ratio test, at half the LINKING distance. Without it a nearly
        % stationary track (median step ≈ localization noise) flags every ordinary jitter as a huge
        % multiple of nothing: on the WithER cell, ratio alone at 3x flagged 649 of 838 tracks, which
        % is not triage. Tied to the linking radius rather than a fixed µm so it travels between
        % datasets — a step approaching that radius is the tracker at the limit of what it may link.
        f = 0.4;
        if isfield(c,'link_dist') && isgraphics(c.link_dist) && c.link_dist.Value>0
            f = c.link_dist.Value/2;
        end
    end

    function link_goto(delta)
        % Walk the links of the SELECTED track. With nothing on the cursor yet, land on the most
        % suspicious link rather than link 1 — on a 58-link track that is the whole point.
        L = link_info(S.selected_id);
        if isempty(L.step), clog('LINK: select a track with at least 2 localizations.'); return; end
        n = numel(L.step);
        if isempty(S.linkIdx)
            [~, S.linkIdx] = max(L.ratio);
        else
            S.linkIdx = S.linkIdx + delta;
            if S.linkIdx < 1, S.linkIdx = n; elseif S.linkIdx > n, S.linkIdx = 1; end   % wrap
        end
        show_link_cursor(L);
    end

    function link_goto_worst()
        L = link_info(S.selected_id);
        if isempty(L.step), return; end
        [~, S.linkIdx] = max(L.ratio);
        show_link_cursor(L);
    end

    function link_next_susp_in_track()
        % Next FLAGGED link inside this track, wrapping. Walking all 58 links one by one is exactly
        % the tedium the screenshot showed; usually only a handful are worth looking at.
        L = link_info(S.selected_id);
        if isempty(L.step), clog('LINK: select a track first.'); return; end
        idx = find(L.susp);
        if isempty(idx)
            clog('LINK: no flagged link in track %g (max %.3f µm = %.1f× median %.3f µm).', ...
                S.selected_id, max(L.step), max(L.ratio), L.med);
            return;
        end
        cur = S.linkIdx; if isempty(cur), cur = 0; end
        nxt = idx(find(idx > cur, 1)); if isempty(nxt), nxt = idx(1); end
        S.linkIdx = nxt; show_link_cursor(L);
    end

    function show_link_cursor(L)
        if nargin < 1, L = link_info(S.selected_id); end
        if isempty(L.step) || isempty(S.linkIdx), return; end
        % A cut shortens the chain the cursor was indexing, so the index can outlive its list.
        % Drop it rather than reading past the end.
        if S.linkIdx < 1 || S.linkIdx > numel(L.step)
            S.linkIdx = []; clear_link_playback();
            c.cut_btn.Enable = 'off'; c.cut_btn.Text = '✂ Cut link';
            c.link_lbl.Text = 'Track changed — pick a link again with ◀ / ▶ or ▲ Worst.';
            c.link_lbl.FontColor = [0.2 0.2 0.2];
            return;
        end
        k = S.linkIdx;
        c.link_lbl.Text = sprintf(['link %d of %d   ·   %.3f µm  =  %.1f× this track''s median (%.3f µm)%s%s\n' ...
            'frames %d → %d   ·   cut removes the link, keeping both halves'], ...
            k, numel(L.step), L.step(k), L.ratio(k), L.med, ...
            tern_(L.gap(k), '  ·  GAP-CLOSED', ''), tern_(L.susp(k), '  ·  ⚠ FLAGGED', ''), ...
            round(L.t0(k)/S.frame_interval), round(L.t1(k)/S.frame_interval));
        if L.susp(k), c.link_lbl.FontColor = [0.75 0.15 0.10]; else, c.link_lbl.FontColor = [0.2 0.2 0.2]; end
        c.cut_btn.Enable = 'on';
        c.cut_btn.Text   = sprintf('✂ Cut link %d  (%.2f µm)', k, L.step(k));
        % Park the movie on the frame the link DEPARTS from, and scope playback to the link's own
        % window. Without this the trajectory drew the candidate segment while the raw frame behind it
        % was still the track's first — you were judging a link against pixels from another moment.
        f0 = round(L.t0(k)/S.frame_interval); f1 = round(L.t1(k)/S.frame_interval);
        % Clamp to the track's own span: past frame_end there are no localizations, and overlayImage
        % silently clamps an out-of-range page, so the loop would sit on a repeated last frame with
        % nothing on it while the title kept counting.
        tmk = S.track_metrics(S.track_metrics.TRACK_ID==S.selected_id,:);
        hiCap = f1 + S.linkPad;
        if ~isempty(tmk), hiCap = min(hiCap, tmk.frame_end); end
        if S.spt_nfr > 0, hiCap = min(hiCap, S.spt_nfr-1); end
        S.playRange = [max(0, f0-S.linkPad), max(hiCap, f1)];
        update_link_strip(); update_disp_plot(); update_trajectory(f0);
        publish_state();     % so the cursor is visible to the headless test hooks
    end

    function cut_current()
        L = link_info(S.selected_id);
        if isempty(L.step) || isempty(S.linkIdx), clog('CUT: no link on the cursor.'); return; end
        do_cut(L.spotId(S.linkIdx));
    end

    function on_strip_click(e)
        % Both the strip and the step plot below map a click to the same edge: nearest by time. The
        % step plot draws step i at the time of the spot it ARRIVES at, so nearest-midpoint works for
        % the strip and nearest-endpoint for the plot; taking the enclosing interval handles both.
        if ~S.loaded || isempty(S.selected_id) || isempty(S.strip.spotId)
            clog('CUT: select a track first.'); return;
        end
        x = e.IntersectionPoint(1);
        k = find(S.strip.t0 <= x & S.strip.t1 >= x, 1);
        if isempty(k)
            [~,k] = min(abs((S.strip.t0 + S.strip.t1)/2 - x));    % outside every span: nearest edge
        end
        % A click SELECTS the link; the cut is a separate, deliberate press. Cutting straight from a
        % click made an irreversible edit out of a mis-aimed click on a strip 58 links wide.
        S.linkIdx = k;
        show_link_cursor();
    end

    function [ids, nLinks] = flagged_tracks()
        % Every KEPT track holding a flagged link, ranked worst-first by how far its biggest step
        % stands out from its own median. With ~100 candidates in a real cell, visiting them in
        % track-id order buries the egregious ones; severity order puts the decision first.
        ids = []; nLinks = 0; sc = [];
        if ~S.loaded, return; end
        for tid = S.kept_ids(:)'
            L = link_info(tid);
            if isempty(L.step) || ~any(L.susp), continue; end
            ids(end+1,1) = tid; sc(end+1,1) = max(L.ratio); nLinks = nLinks + sum(L.susp); %#ok<AGROW>
        end
        [~,o] = sort(sc,'descend'); ids = ids(o);
    end

    function refresh_links()
        % The flag ratio changed: re-colour, re-label, and re-count the workload it implies.
        if ~S.loaded, return; end
        [ids, nLinks] = flagged_tracks();
        nk = numel(S.kept_ids);
        c.flag_lbl.Text = sprintf('%d link(s) in %d of %d kept track(s) — %.0f%%', ...
            nLinks, numel(ids), nk, 100*numel(ids)/max(nk,1));
        if numel(ids) > 0.4*nk, c.flag_lbl.FontColor = [0.75 0.35 0.05];   % too many to review
        else, c.flag_lbl.FontColor = [0.25 0.45 0.25]; end
        if isempty(S.selected_id), return; end
        update_link_strip(); update_disp_plot();
        if ~isempty(S.linkIdx), show_link_cursor(); end
    end

    function next_suspicious()
        % Next KEPT track holding a flagged link, resuming after the current one and wrapping. Lands
        % ON that track's worst link, so a press puts the cursor where the decision is.
        if ~S.loaded, clog('NEXT TRACK: nothing loaded.'); return; end
        [ids, nLinks] = flagged_tracks();
        if isempty(ids)
            clog('NEXT TRACK: no kept track has a link ≥ %.1f× its own median and ≥ %.2f µm.', ...
                ratio_thr(), step_floor());
            c.status.Text = sprintf('Nothing flagged at ≥ %.1f× median — lower the ratio to widen the net.', ratio_thr());
            return;
        end
        at = 0; if ~isempty(S.selected_id), at = find(ids==S.selected_id,1); if isempty(at), at = 0; end, end
        nxt = ids(mod(at, numel(ids)) + 1);          % advance down the ranked list, wrapping
        S.linkIdx = []; clear_link_playback();   % select_track's guard cannot fire: selected_id is set below
        S.selected_id = nxt; select_track(nxt);
        link_goto_worst();
        L = link_info(nxt);
        clog('⚠ [%d/%d worst-first] track %g: %d flagged link(s), worst %.3f µm = %.1f× its median %.3f µm.', ...
            mod(at,numel(ids))+1, numel(ids), nxt, sum(L.susp), max(L.step), max(L.ratio), L.med);
        c.status.Text = sprintf('Track %g (%d of %d flagged) — worst link %.2f µm = %.1f× median · %d links total flagged', ...
            nxt, mod(at,numel(ids))+1, numel(ids), max(L.step), max(L.ratio), nLinks);
    end

    function update_disp_plot()
        if ~S.loaded||isempty(S.selected_id), return, end
        cla(ax_dv2); hold(ax_dv2,'on');
        sel=sortrows(S.spots_t(S.spots_t.TRACK_ID==S.selected_id,:),'FRAME');
        if height(sel)<2, return, end
        dx=diff(sel.X_um); dy=diff(sel.Y_um); d=sqrt(dx.^2+dy.^2);
        t_s=sel.FRAME(2:end)*S.frame_interval;
        plot(ax_dv2,t_s,d,'-o','Color',[0.20 0.60 0.86],...
            'MarkerSize',2,'LineWidth',0.8,'HitTest','off','PickableParts','none');
        yline(ax_dv2,mean(d),'--r','LineWidth',0.8);
        % Mark the same links the strip above flags, so the spike and the edge read as one object.
        L = link_info(S.selected_id);
        if ~isempty(L.step) && any(L.susp)
            plot(ax_dv2,t_s(L.susp),d(L.susp),'o','MarkerSize',6,'LineWidth',1.4, ...
                'MarkerEdgeColor',[0.85 0.15 0.15],'HitTest','off','PickableParts','none');
        end
        % the relative gate is what flags a mislinkage in a confined track; draw it, not the absolute one
        yline(ax_dv2, ratio_thr()*median(d), ':', 'Color',[0.85 0.15 0.15],'LineWidth',0.8);
        if ~isempty(S.linkIdx) && ~isempty(L.step) && S.linkIdx>=1 && S.linkIdx<=numel(d)
            xline(ax_dv2, t_s(S.linkIdx), '-', 'Color',[0.85 0.55 0], 'LineWidth',1.6);
            plot(ax_dv2, t_s(S.linkIdx), d(S.linkIdx), 'o','MarkerSize',9,'LineWidth',2, ...
                'MarkerEdgeColor',[0.85 0.55 0],'HitTest','off','PickableParts','none');
        end
        title(ax_dv2,'Step displacements — click to select that link','FontSize',9);
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
        man_store();                                  % persist against this cell straight away

        clog('%s track %d  (now %d kept / %d rejected · %d manual override%s)', st, sid, ...
            numel(S.kept_ids), height(S.track_metrics)-numel(S.kept_ids), ...
            numel(S.manual_keep)+numel(S.manual_reject), ...
            tern_(numel(S.manual_keep)+numel(S.manual_reject)==1,'','s'));
        select_track(sid);            % refresh the label, the button colour and the overview
        if strcmp(c.show_mode.Value,'rej'), do_reshuffle(); end   % it left the review pool
    end

    function do_play()
        if ~S.loaded||isempty(S.selected_id), return, end
        % Stop whatever is already running FIRST. Overwriting S.play_timer left the previous timer
        % running with nothing pointing at it — it kept firing into this closure forever, holding the
        % whole workspace alive. A stale timer from a previous app instance is how you get
        % "Unrecognized field name" for a field the current file plainly initializes: the orphan is
        % executing the OLD code against the OLD S, while MATLAB prints line numbers from the new file.
        do_pause();
        S.playing=true;
        S.play_timer=timer('ExecutionMode','fixedRate','Tag',TIMER_TAG,...
            'Period',round(max(0.033,1/c.fps.Value)*1000)/1000,...   % ms precision (timer requires it)
            'TimerFcn',@(~,~) advance_frame());
        start(S.play_timer);
        publish_state();   % the playing flag was never republished, so it read stale to any observer
    end

    function do_pause()
        S.playing=false;
        if ~isempty(S.play_timer)&&isvalid(S.play_timer)
            stop(S.play_timer); delete(S.play_timer);
        end
        S.play_timer = [];
        publish_state();
    end

    function advance_frame()
        if ~S.loaded||~S.playing||isempty(S.selected_id), return, end
        f_next = S.current_frame + 1;
        if ~isempty(S.playRange) && S.linkLoop
            % looping the few frames around one link: the molecule crosses the suspect step over and
            % over, which is the only way to see whether the spot really moved there or the tracker
            % jumped to a different one
            % Clamp BOTH ends. Wrapping only at the top let the frame escape below the window —
            % re-selecting the same track resets current_frame to the track's first frame, and the
            % loop then crept through every frame up to playRange(2) inside a link-sized crop, which
            % reads as a hang.
            if f_next > S.playRange(2) || f_next < S.playRange(1), f_next = S.playRange(1); end
        else
            tm_sel=S.track_metrics(S.track_metrics.TRACK_ID==S.selected_id,:);
            if f_next>tm_sel.frame_end, f_next=tm_sel.frame_start; end
        end
        update_trajectory(f_next);
    end

    function clear_link_playback()
        % The link window describes a chain that has just changed or gone. Leaving it set would keep
        % playback looping a handful of frames belonging to nothing, which reads as a frozen movie.
        S.playRange = [];
        if S.linkLoop
            S.linkLoop = false;
            if S.playing, do_pause(); end     % stop rather than silently switch to whole-track play
        end
        if isfield(c,'cut_btn') && isgraphics(c.cut_btn)
            c.cut_btn.Enable = 'off'; c.cut_btn.Text = '✂ Cut link';
        end
    end

    function tf = zoom_to_link()
        tf = true;
        if isfield(c,'zoom_link') && isgraphics(c.zoom_link), tf = c.zoom_link.Value; end
    end

    function set_link_pad()
        S.linkPad = round(c.link_pad.Value);
        if ~isempty(S.linkIdx), show_link_cursor(); end   % re-scope the window around the same link
    end

    function play_whole_track()
        % The green Play button always means the WHOLE track. Without clearing the flag it would keep
        % looping the 5-frame link window set by the last cursor move, which looks like a hang.
        S.linkLoop = false;
        do_play();
    end

    function play_link()
        % Loop the frames spanning the link on the cursor. Stepping the cursor already parks the movie
        % at the departure frame; this makes the spots actually move across it.
        if isempty(S.linkIdx) || isempty(S.playRange)
            clog('PLAY LINK: pick a link first (◀ / ▶ or ▲ Worst).'); return;
        end
        S.linkLoop = true;
        update_trajectory(S.playRange(1));
        do_play();
        clog('▶ looping frames %d–%d across link %d (%d fps)', ...
            S.playRange(1), S.playRange(2), S.linkIdx, c.fps.Value);
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
        if ~S.loaded
            clog('EXPORT: nothing loaded — nothing to do.');
            c.status.Text = 'Nothing loaded to export.'; return
        end
        out_dir=strtrim(strjoin(c.export_dir.Value,''));
        if isempty(out_dir)
            out_dir=uigetdir('.','Select output folder');
            if isequal(out_dir,0), clog('EXPORT: cancelled at the folder picker.'); return, end
        end
        setBusy(true, c.export_btn, '⏳ exporting…');
        expGuard = onCleanup(@() setBusy(false, c.export_btn)); %#ok<NASGU>
        tExp = tic;
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
        % Emitted from S.spots_t, NOT from the parsed input DOM. The DOM only knows the tracks the
        % tracker produced; after a link cut the kept ids include minted fragment ids that match no
        % <Track> node, so walking the DOM would silently drop every repaired track.
        xdoc = S.xml_doc; root = xdoc.getDocumentElement();
        fid = fopen(fullfile(out_dir,[base_name '_tracks_' S.exportSuffix '.xml']),'w');
        fprintf(fid,'<?xml version="1.0" encoding="UTF-8"?>\n');
        fprintf(fid,'<Tracks nTracks="%d" frameInterval="%s" spaceUnit="%s" timeUnit="%s">\n',...
            numel(good_ids),...
            char(root.getAttribute('frameInterval')),...
            char(root.getAttribute('spaceUnit')),...
            char(root.getAttribute('timeUnit')));
        for gi = 1:numel(good_ids)
            tr = sortrows(S.spots_t(S.spots_t.TRACK_ID==good_ids(gi),:),'FRAME');
            if height(tr)==0, continue, end
            fprintf(fid,'  <Track TRACK_ID="%d" N_SPOTS="%d">\n', good_ids(gi), height(tr));
            for si = 1:height(tr)
                fprintf(fid,'    <Spot SPOT_ID="%d" FRAME="%d" T="%.6f" X="%.6f" Y="%.6f" Z="0.0"/>\n',...
                    tr.SPOT_ID(si), tr.FRAME(si), tr.FRAME(si)*S.frame_interval, tr.X_um(si), tr.Y_um(si));
            end
            fprintf(fid,'  </Track>\n');
        end
        fprintf(fid,'</Tracks>\n'); fclose(fid);

        % 5. Builtin TrackMate XML — filter particles matching good TRACK_IDs
        % The builtin XML uses <particle> nodes in order matching track indices.
        % We match by position: sort all_ids, find which positions are kept.
        % That positional mapping only holds while the track set is the tracker's own. A link cut
        % splits one chain into two, so the i-th kept id no longer names the i-th particle and the
        % file would be silently mis-assigned. Skip it rather than write a wrong one — the custom XML
        % above is what the importer reads.
        if ~isempty(S.builtin_xml_doc) && ~isempty(S.cuts)
            clog('   builtin XML skipped — %d link cut(s) mean its particle order no longer matches.', numel(S.cuts));
        elseif ~isempty(S.builtin_xml_doc)
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
        nman = numel(S.manual_keep) + numel(S.manual_reject);
        clog('▶ EXPORT %s · %s', base_name, hms_(toc(tExp)));
        clog('   %d kept / %d rejected of %d%s%s', numel(good_ids), n_removed, numel(all_ids), ...
            tern_(nman>0, sprintf(' · %d manual override%s honoured', nman, tern_(nman==1,'','s')), ''), ...
            tern_(~isempty(S.cuts), sprintf(' · %d link cut%s applied', numel(S.cuts), tern_(numel(S.cuts)==1,'','s')), ''));
        clog('   thresholds: disp var <= %.4f · density <= %.0f%s', c.max_dv.Value, c.max_dn.Value, ...
            tern_(isfield(c,'reject_jumps') && isgraphics(c.reject_jumps) && c.reject_jumps.Value, ...
                  sprintf(' · jump gate > %.3g µm', c.gap_dist.Value), ''));
        clog('   -> %s  [_tracks_%s.xml · _spots_%s.csv · _track_metrics.csv · _filter_log.csv]', ...
            out_dir, S.exportSuffix, S.exportSuffix);
        % No modal box: it blocked the app and told you nothing the log does not. The status line
        % plus the log entry above are the confirmation, the same way Tool 1's Track tab reports.
        c.status.Text = sprintf('✔ Exported %s — kept %d, removed %d  ->  %s', ...
            base_name, numel(good_ids), n_removed, out_dir);
        c.status.FontColor = [0.15 0.50 0.20];
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
        setBusy(true, c.batch_btn, '⏳ batch running…');
        bGuard = onCleanup(@() setBusy(false, c.batch_btn)); %#ok<NASGU>
        man_store();          % flush the open cell's decisions so the batch honours them too
        cuts_store();         % ...and its link cuts, for the same reason
        tBatch = tic;
        nman_all = 0; ks = S.manual_by_cell.keys;
        for q = 1:numel(ks), mm = S.manual_by_cell(ks{q}); nman_all = nman_all + numel(mm.keep) + numel(mm.reject); end
        ncut_all = 0; kc = S.cuts_by_cell.keys;
        for q = 1:numel(kc), ncut_all = ncut_all + numel(S.cuts_by_cell(kc{q}).cuts); end
        clog('▶ BATCH %d cell(s) · disp var <= %.4f · density <= %.0f%s%s%s', n_files, thr_dv, thr_dn, ...
            tern_(jump_on, sprintf(' · jump > %.3g µm', thr_jump), ''), ...
            tern_(nman_all>0, sprintf(' · %d manual override(s) preserved', nman_all), ''), ...
            tern_(ncut_all>0, sprintf(' · %d link cut(s) applied', ncut_all), ''));
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

                % Re-apply this cell's link cuts BEFORE the metrics, so the batch measures the repaired
                % chains — not the mislinked ones the tracker wrote. Without this a cut made by hand
                % would be silently undone by any batch run, the way manual keeps once were.
                ncut_b = 0;
                if isKey(S.cuts_by_cell, man_key(base_nm))
                    rc = S.cuts_by_cell(man_key(base_nm)); ncut_b = numel(rc.cuts);
                    if ncut_b > 0
                        spots_t_b = apply_cuts_to(spots_t_b, rc.cuts);
                        spots_t_b = sortrows(spots_t_b,{'TRACK_ID','FRAME'});
                    end
                end

                % Crowding + motion metrics — SAME function as the interactive filter, at the same
                % radius and statistic. The cloud is THIS cell's, built from the CSV just read: the
                % crowding measure counts every detection in the field, not only the tracked ones.
                okb_ = isfinite(spots_j.FRAME) & isfinite(spots_j.X_um) & isfinite(spots_j.Y_um);
                cloud_b = [spots_j.FRAME(okb_), spots_j.X_um(okb_), spots_j.Y_um(okb_)];
                tm_b        = compute_metrics_from_spots(spots_t_b, cloud_b);
                track_ids_b = tm_b.TRACK_ID;
                n_tb        = height(tm_b);
                mean_dn_b   = tm_b.mean_local_density; % worst-case (max) density per track
                disp_var_b  = tm_b.disp_variance;

                % Apply the SAME absolute thresholds the interactive Curate filter uses — via
                % the shared helper, so batch == what you saw on the tuning cell.
                keep_mask    = ids_from_abs_thresh(tm_b);
                good_ids_b   = track_ids_b(keep_mask);
                % ...then re-apply THIS cell's manual keep/reject on top. A batch run must never
                % silently overrule a decision the user made by hand; it previously ignored them
                % entirely, so reviewing a cell and then batching threw that work away.
                mk = []; mr = [];
                if isKey(S.manual_by_cell, man_key(base_nm))
                    mm = S.manual_by_cell(man_key(base_nm)); mk = mm.keep(:); mr = mm.reject(:);
                end
                nman_b = numel(mk) + numel(mr);
                if nman_b > 0
                    good_ids_b = union(setdiff(good_ids_b, mr), intersect(mk, track_ids_b));
                    good_ids_b = good_ids_b(:);
                end
                removed_ids_b = setdiff(track_ids_b, good_ids_b);

                % Export the filtered custom XML under the SAME suffix the interactive export uses.
                % This was hardcoded '_tracks_filtered.xml': in Tool 2 (readPrefer='filtered',
                % exportSuffix='curated') the batch reads Tool 1's _tracks_filtered.xml and, with the
                % out-dir box defaulting to that same tracks/ folder, wrote straight back over its own
                % input — Tool 1's tracking output replaced by the twice-filtered result, unrecoverably.
                xmlOut = fullfile(out_dir,[base_nm '_tracks_' S.exportSuffix '.xml']);
                if same_file_(xmlOut, xml_path)
                    clog('   %s: SKIPPED — output would overwrite the input (%s).', base_nm, xmlOut);
                    continue;
                end
                fid_x = fopen(xmlOut,'w');
                fprintf(fid_x,'<?xml version="1.0" encoding="UTF-8"?>\n');
                fprintf(fid_x,'<Tracks nTracks="%d" frameInterval="%.6f" spaceUnit="%s" timeUnit="%s">\n',...
                    numel(good_ids_b), fi_val,...
                    char(root_b.getAttribute('spaceUnit')),...
                    char(root_b.getAttribute('timeUnit')));
                % Emitted from the (cut-aware) spot table, not from the input DOM: after a link cut the
                % kept ids include minted fragment ids that match no <Track> node, so walking the DOM
                % would drop every repaired track without a word.
                for gi = 1:numel(good_ids_b)
                    trb = sortrows(spots_t_b(spots_t_b.TRACK_ID==good_ids_b(gi),:),'FRAME');
                    if height(trb)==0, continue, end
                    fprintf(fid_x,'  <Track TRACK_ID="%d" N_SPOTS="%d">\n', good_ids_b(gi), height(trb));
                    for si = 1:height(trb)
                        fprintf(fid_x,'    <Spot SPOT_ID="%d" FRAME="%d" T="%.6f" X="%.6f" Y="%.6f" Z="0.0"/>\n',...
                            trb.SPOT_ID(si), trb.FRAME(si), trb.FRAME(si)*fi_val, trb.X_um(si), trb.Y_um(si));
                    end
                    fprintf(fid_x,'  </Track>\n');
                end
                fprintf(fid_x,'</Tracks>\n'); fclose(fid_x);

                % Export builtin XML if available. Its <particle> nodes are matched to tracks BY
                % POSITION, so a link cut (which changes the track count) invalidates the mapping —
                % skip rather than write a mis-assigned file.
                if ncut_b > 0 && ~isempty(blt_path) && isfile(blt_path)
                    clog('   %s: builtin XML skipped — %d link cut(s) change the particle order.', base_nm, ncut_b);
                elseif ~isempty(blt_path) && isfile(blt_path)
                    blt_doc   = xmlread(blt_path);
                    blt_root  = blt_doc.getDocumentElement();
                    parts_b   = blt_doc.getElementsByTagName('particle');
                    sorted_all_b  = sort(track_ids_b);
                    bltOut = fullfile(out_dir,[base_nm '_tracks_builtin_' S.exportSuffix '.xml']);
                    if same_file_(bltOut, blt_path)
                        clog('   %s: builtin XML skipped — would overwrite the input.', base_nm);
                        bltOut = '';
                    end
                  if ~isempty(bltOut)
                    fid_b2 = fopen(bltOut,'w');
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
                end

                % Spots CSV + track metrics — the interactive export writes both and the batch wrote
                % neither, so a batch-only run produced tracks with no localization data beside them:
                % TrackImporter_direct then found no matching _spots_<suffix>.csv and silently built
                % the TrackStruct with no intensities, no MITO_DIST_UM and no ER_DIST_UM.
                spotsOut_b = fullfile(out_dir,[base_nm '_spots_' S.exportSuffix '.csv']);
                if same_file_(spotsOut_b, csv_path)
                    clog('   %s: spots CSV skipped — would overwrite the input.', base_nm);
                elseif S.preserveCloud
                    export_cloud(csv_path, good_ids_b, spotsOut_b);   % every detection, TRACK_ID blanked
                else
                    sk = spots_t_b(ismember(spots_t_b.TRACK_ID, good_ids_b),:);
                    sk = removevars(sk, intersect({'LOCAL_DENSITY'}, sk.Properties.VariableNames));
                    writetable(sk, spotsOut_b);
                end
                tmk = tm_b; tmk.KEEP = ismember(tmk.TRACK_ID, good_ids_b);
                writetable(tmk, fullfile(out_dir,[base_nm '_track_metrics.csv']));

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

                clog('   %s · %d -> %d kept (%d rejected)%s%s', base_nm, n_tb, numel(good_ids_b), ...
                    numel(removed_ids_b), tern_(nman_b>0, sprintf(' · %d manual', nman_b), ''), ...
                    tern_(ncut_b>0, sprintf(' · %d cut', ncut_b), ''));
            catch ME
                clog('   %s: ERROR — %s', base_nm, ME.message);
                warning('Batch filter failed on %s: %s', base_nm, ME.message);
            end
        end

        % Write HTML report
        html_path = fullfile(out_dir,'batch_filter_report.html');
        write_html_report(batch_results, html_path, thr_dv, thr_dn, jump_on, thr_jump);

        if ~isempty(dlg) && isvalid(dlg), dlg.Value=1; dlg.Message='Done'; close(dlg); end
        clog('✔ BATCH done — %d cell(s) in %s', n_files, hms_(toc(tBatch)));
        clog('   -> %s  [per cell: _tracks_%s.xml · _spots_%s.csv · _track_metrics.csv · _filter_log.csv]', ...
            out_dir, S.exportSuffix, S.exportSuffix);
        clog('   -> %s', html_path);
        c.status.Text = sprintf('✔ Batch done: %d files in %s. Report: %s', n_files, hms_(toc(tBatch)), html_path);
        c.status.FontColor = [0.15 0.50 0.20];
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

function spt_curate_layout_smoke()
%SPT_CURATE_LAYOUT_SMOKE  The Import & Curate controls must be reachable and next to what they drive.
%
% Four separate ways this tab put controls where they could not be used:
%
%   1. Play/Pause/FPS were built into the far-left control column, about 1240 px from the movie they
%      drive — you set the frame rate at one edge of the window and watched the result at the other.
%   2. Every row label spanned BOTH columns while its control sat in column 2, so six of them ran
%      underneath their own spinner.
%   3. The control grid declared 60 rows and had grown to 70. MATLAB invents the extra rows as '1x',
%      and a '1x' row in a SCROLLABLE grid is zero pixels tall, so ten controls — the mito colour
%      picker among them — were laid out at h=0 and simply could not be seen.
%   4. The KEEP/REJECT button, the control the whole tab exists for, sat inside the scrolling column
%      straddling the fold, in ~1450 px of content shown through a ~670 px viewport.
%
% Each is invisible in code review and obvious on screen, so this measures the built figure.

proj = fullfile(tempdir,'spt_curate_layout'); if isfolder(proj), rmdir(proj,'s'); end
mkdir(fullfile(proj,'tracks'));
make_cell(proj,'cellA',12);

f = uifigure('Visible','off','Position',[1 1 1320 900]);
pn = uipanel(f);
track_viewer(pn, proj, [], {}, struct('readPrefer','raw','exportSuffix','curated','preserveCloud',true));
drawnow; pause(1.5);

% --- transport now lives with the video ---
bs = findobj(f,'Type','uibutton');
pl = bs(arrayfun(@(x) strcmp(strtrim(string(x.Text)),'Play'), bs));
pa = bs(arrayfun(@(x) strcmp(strtrim(string(x.Text)),'Pause'), bs));
% the assertion that matters: Play is INSIDE the Selected-track panel, with the video
pans = findobj(f,'Type','uipanel');
sel = pans(arrayfun(@(x) strcmp(string(x.Title),'Selected track'), pans));
assert(~isempty(pl) && ~isempty(pa), 'Play/Pause not found by exact label');
assert(~isempty(sel), 'Selected track panel not found');
inSel = @(h) ~isempty(ancestorPanel(h, sel(1)));
fprintf('Play inside "Selected track": %d\n', inSel(pl(1)));
fprintf('Pause inside "Selected track": %d\n', inSel(pa(1)));
assert(inSel(pl(1)) && inSel(pa(1)), 'the transport is still not with the video');
pp = getabs(pl(1)); sp_ = getabs(sel(1));
fprintf('Selected-track panel x=%.0f ; Play x=%.0f ; offset %.0f px (was ~1243 from the video)\n', ...
    sp_(1), pp(1), abs(pp(1)-sp_(1)));

% --- labels no longer run under their controls ---
gl = findobj(f,'Type','uigridlayout');
lgv = gl(arrayfun(@(g) numel(g.RowHeight)>40, gl));
assert(~isempty(lgv),'control grid not found');
lgv = lgv(1);
col2x = inf; over = 0; worst = '';
for ch = lgv.Children'
    try, if isequal(ch.Layout.Column,2), col2x = min(col2x, ch.Position(1)); end, catch, end
end
for ch = lgv.Children'
    if ~isa(ch,'matlab.ui.control.Label'), continue; end
    try
        if isequal(ch.Layout.Column,1) && ch.Position(1)+ch.Position(3) > col2x + 1
            over = over + 1; worst = char(ch.Text);
        end
    catch, end
end
fprintf('column 2 starts at x=%.1f; labels overrunning it: %d %s\n', col2x, over, worst);
assert(over == 0, '%d label(s) still overlap their control (e.g. "%s")', over, worst);

% --- FPS still findable the way the test finds it ---
sp = findobj(f,'Type','uispinner');
fps = sp(arrayfun(@(x) isequal(x.Limits,[1 60]), sp));
assert(numel(fps)==1 && ~isempty(fps(1).ValueChangedFcn), 'the FPS spinner contract broke');
fprintf('FPS spinner: 1 found, live callback intact\n');

% --- the decision button must be visible without scrolling ---
tb = bs(arrayfun(@(x) contains(string(x.Text),'keep/reject')|contains(string(x.Text),'KEEP')|contains(string(x.Text),'REJECT'), bs));
assert(~isempty(tb), 'decision button not found');
scr = gl(arrayfun(@(g) strcmp(g.Scrollable,'on'), gl));
inScroll = false;
for k=1:numel(scr), if ~isempty(ancestorPanel(tb(1), scr(k))), inScroll = true; end, end
tp = getabs(tb(1));
fprintf('decision button: inside a scrollable grid = %d, y=%.0f h=%.0f, fig h=%d\n', ...
    inScroll, tp(2), tp(4), f.Position(4));
assert(~inScroll, 'the decision button is still inside the scrolling column');
assert(tp(2) > 0 && tp(2)+tp(4) <= f.Position(4), 'the decision button is off-screen');

% --- control column content still fits its declared rows ---
fprintf('control grid rows declared=%d, "1x"=%d\n', numel(lgv.RowHeight), ...
    sum(cellfun(@(x) ischar(x)||isstring(x), lgv.RowHeight)));
z=0; for ch=lgv.Children', try, if ch.Position(4)<=0.5, z=z+1; end, catch, end, end
fprintf('controls at zero height: %d\n', z);
assert(z==0, '%d control(s) collapsed', z);

close(f);
% ---- the manual overlay pickers are gone from the normal flow -------------------------------------
% The overlay resolves itself: the ER and mito folders come from the Experiment tab and the channel
% token is derived from the file names. "Pick ER" only ever meant "the automatic match failed", and
% it had no way to say so. It survives on the status label's context menu as the escape hatch.
bs2 = findobj(f,'Type','uibutton');
bt = strings(0,1);
for q = 1:numel(bs2), bt(end+1,1) = string(bs2(q).Text); end %#ok<AGROW>
assert(~any(contains(bt,'Pick ER')) && ~any(contains(bt,'Pick mito')), ...
    'the manual overlay pickers are still taking rows in the control column');
src = fileread(fullfile(fileparts(mfilename('fullpath')),'track_viewer.m'));
% The menu items are GENERATED per declared channel now, so this can no longer pin the literal
% 'Pick an ER image manually'. The intent is unchanged: a failed auto-match must stay recoverable,
% so there must still be a manual picker wired to pick_overlay on the status label's context menu.
assert(contains(src,'image manually') && contains(src,'pick_overlay('), ...
    'the manual picker was removed with no escape hatch — a failed auto-match would be unrecoverable');
assert(contains(src,'c.ov_lbl.ContextMenu'), 'the picker is no longer on the status label context menu');
% ...and it must be one per channel, not a hard-coded pair.
assert(contains(src,'for kvMenu'), 'the manual pickers are hard-coded again rather than generated');
fprintf('overlay pickers generated per channel, on the status label''s context menu\n');

fprintf('\nALL CURATE-LAYOUT ASSERTIONS PASSED.\n');
end

function a = ancestorPanel(h, target)
a = []; q = h.Parent;
while ~isempty(q) && ~isa(q,'matlab.ui.Figure')
    if isequal(q, target), a = q; return; end
    q = q.Parent;
end
end

function p = getabs(h)
p = h.Position; a = h.Parent;
while ~isa(a,'matlab.ui.Figure')
    try, q = a.Position; p(1)=p(1)+q(1); p(2)=p(2)+q(2); catch, end
    a = a.Parent;
end
end

function make_cell(proj, base, n)
% Minimal tracks XML + spots CSV pair — enough for track_viewer to load a cell.
td = fullfile(proj,'tracks');
fx = fopen(fullfile(td,[base '_tracks.xml']),'w');
fprintf(fx,'<?xml version="1.0" encoding="UTF-8"?>\n<Tracks nTracks="%d" frameInterval="0.02" spaceUnit="um" timeUnit="s">\n', n);
fc = fopen(fullfile(td,[base '_spots.csv']),'w');
fprintf(fc,['TRACK_ID,SPOT_ID,FRAME,T_s,X_um,Y_um,QUALITY,MEAN_INTENSITY,MAX_INTENSITY,' ...
            'TOTAL_INTENSITY,MITO_DIST_UM,ER_DIST_UM,ELONGATION,ORIENT_DEG\n']);
sid = 0;
for t = 1:n
    fprintf(fx,'  <Track TRACK_ID="%d">\n', t-1);
    for j = 1:8
        x = 5+0.1*j+t; y = 5+0.1*j;
        fprintf(fx,'    <Spot FRAME="%d" T="%.6f" X="%.6f" Y="%.6f" Z="0.0" SPOT_ID="%d"/>\n', j-1,(j-1)*0.02,x,y,sid);
        fprintf(fc,'%d,%d,%d,%.6f,%.4f,%.4f,100,50,80,500,,,,\n', t-1, sid, j-1, (j-1)*0.02, x, y);
        sid = sid + 1;
    end
    fprintf(fx,'  </Track>\n');
end
fprintf(fx,'</Tracks>\n'); fclose(fx); fclose(fc);
end

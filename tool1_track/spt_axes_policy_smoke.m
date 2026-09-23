function spt_axes_policy_smoke()
%SPT_AXES_POLICY_SMOKE  No plot may be left armed with a hover data tip.
%
% The warning this prevents:
%
%   Error occurred while executing the listener callback for event Action defined for class
%   matlab.graphics.interaction.graphicscontrol.AxesControl: Invalid or deleted object.
%   ... Linger/motionCallback ... DataTipHoverLingerInteraction/handleEvent
%
% Mechanism: the default uiaxes interactions include a hover data tip, which arms a linger timer
% against a specific graphics object as soon as the pointer rests on one. Every plot in these apps is
% redrawn by cla() + fresh plot calls, so if a redraw lands between the hover and the timer firing,
% the timer wakes holding a handle cla already deleted. Nothing of ours is on that stack — the
% listener belongs to the interaction — so the only fix is to not arm it.
%
% This checks the mechanism directly (the interaction is gone) and then sweeps every app for an axes
% that still has one, because a new plot added later would silently reintroduce the warning.

here = fileparts(mfilename('fullpath')); addpath(here);
addpath(fullfile(fileparts(here),'tool2_analyze','app'));
addpath(fullfile(fileparts(here),'tool2_analyze','drivers'));

% ---- 1. the mechanism -----------------------------------------------------------------------------
f = uifigure('Visible','off'); c = onCleanup(@() delete(f));
a = uiaxes(f); plot(a, 1:10);
assert(hasDataTip(a), 'a fresh uiaxes should have the hover data tip — the fixture is wrong');

spt_axes_policy(a);
assert(~hasDataTip(a), '''plot'' mode did not remove the hover data tip');
assert(hasKind(a,'zoom') && hasKind(a,'pan'), '''plot'' mode must KEEP zoom and pan — they hold no per-object handle');
fprintf('plot mode   : data tip removed, zoom+pan kept\n');

b = uiaxes(f); plot(b, 1:10);
spt_axes_policy(b,'click');
assert(isempty(b.Interactions), '''click'' mode should leave no interactions to compete with the click');
fprintf('click mode  : all interactions removed\n');

% ---- 2. it survives the thing that triggers the bug ------------------------------------------------
% cla + redraw is exactly the sequence that orphans the listener's handle.
for k = 1:5, cla(a); plot(a, rand(1,10)); end
assert(~hasDataTip(a), 'the data tip came back after cla + replot');
fprintf('survives cla + replot\n');

% ---- 3. sweep every app ----------------------------------------------------------------------------
% An axes that is cleared and rebuilt must not be left armed. Axes are only exempt if nothing ever
% redraws them, which is not true of any plot in these apps.
apps = {@() spt_app(), @() spt_analyze_app('curate'), @() spt_analyze_app('analysis'), ...
        @() spt_analyze_app('contactsites')};
names = {'spt_app', 'spt_analyze_app curate', 'spt_analyze_app analysis', 'spt_analyze_app contactsites'};
assert(numel(names) == numel(apps), 'the sweep names must keep step with the apps it opens');
bad = {};
for i = 1:numel(apps)
    g = apps{i}(); gc = onCleanup(@() closeQuiet(g));
    g.Position = [1 1 1400 900]; drawnow; pause(0.4);
    axs = findobj(g, 'Type', 'axes');
    n = 0;
    for k = 1:numel(axs)
        if hasDataTip(axs(k))
            n = n + 1;
            bad{end+1} = sprintf('%s: axes "%s"', names{i}, axTitle(axs(k))); %#ok<AGROW>
        end
    end
    fprintf('%-26s %3d axes, %d still armed\n', names{i}, numel(axs), n);
    clear gc;
end
if ~isempty(bad)
    error('spt_axes_policy_smoke:armed', ...
        'these axes still arm a hover data tip and will warn when redrawn under the pointer:\n  %s', ...
        strjoin(bad, sprintf('\n  ')));
end

fprintf('\nALL AXES-POLICY ASSERTIONS PASSED.\n');
end

function tf = hasDataTip(a)
% An axes is ARMED if it still carries the opaque DefaultAxesInteractionSet — that set is what
% includes the hover data tip, and MATLAB does not expand it into a list you can inspect. Once the
% policy has run, Interactions is an explicit array and the data tip is either present by class name
% or genuinely absent.
tf = hasKind(a, 'defaultaxesinteractionset') || hasKind(a, 'datatip');
end

function tf = hasKind(a, kind)
tf = false;
try
    I = a.Interactions;
catch
    return;                                   % no Interactions property -> nothing armed
end
for k = 1:numel(I)
    if contains(lower(class(I(k))), kind), tf = true; return; end
end
end

function t = axTitle(a)
t = '(untitled)';
try, if ~isempty(a.Title) && ~isempty(a.Title.String), t = char(string(a.Title.String)); end, catch, end
end

function closeQuiet(g)
try, delete(timerfindall); catch, end
try, delete(g); catch, end
end

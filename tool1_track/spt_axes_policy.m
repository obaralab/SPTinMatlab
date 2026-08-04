function spt_axes_policy(ax, mode)
%SPT_AXES_POLICY  Make a uiaxes safe to clear and redraw under the mouse.
%
%   spt_axes_policy(ax)            % 'plot'  — keep zoom/pan, drop the hover data tip
%   spt_axes_policy(ax, 'click')   % axes with a ButtonDownFcn — drop everything
%   spt_axes_policy(ax, 'display') % pure display, no inspection wanted — drop everything
%
% THE BUG THIS EXISTS FOR
% Every plot in these apps is redrawn by cla(ax) followed by fresh plot calls. MATLAB's default
% uiaxes interactions include a HOVER DATA TIP, which arms a linger timer the moment the pointer
% rests over a graphics object. If the redraw lands between the hover starting and the timer firing,
% the timer wakes up holding a handle that cla has already deleted, and the callback throws:
%
%   Error occurred while executing the listener callback for event Action defined for class
%   matlab.graphics.interaction.graphicscontrol.AxesControl: Invalid or deleted object.
%   ... Linger/motionCallback ... DataTipHoverLingerInteraction/handleEvent
%
% Nothing in the app is on that stack, so there is nothing to guard with isgraphics — the listener
% belongs to the interaction, not to us. The only fix available from here is to not arm it. Zoom and
% pan hold no per-object handle and are safe, so 'plot' keeps them: they are worth having on a
% histogram or a track map, and removing them would be a real loss to trade for a warning.
%
% A ButtonDownFcn does NOT need 'click': a plain click still reaches the callback with zoom and pan
% present — the contact-site picker's detail axes has shipped that way for a long time. So
% click-to-select axes take 'plot' too, and keep their zoom. 'click' and 'display' exist for axes
% where the built-in gestures are genuinely unwanted, such as a colour bar or a video strip.
%
% NOTE: disableDefaultInteractivity() alone is NOT enough. It disables the gestures but leaves the
% DefaultAxesInteractionSet — and the hover tip — in place, so the two axes that had been opted out
% that way were never actually protected. Assigning Interactions is what removes it.
%
% Accepts an array of axes. Silently ignores anything that is not a live axes, so callers can pass
% handles that may not have been created in this mode.

if nargin < 2 || isempty(mode), mode = 'plot'; end
for k = 1:numel(ax)
    a = ax(k);
    if isempty(a) || ~isgraphics(a), continue; end
    try
        switch lower(char(mode))
            case 'plot'
                % Zoom and pan survive; the hover data tip — the one that arms a timer against a
                % specific object — does not.
                a.Interactions = [zoomInteraction('Dimensions','xy'), panInteraction];
            otherwise
                disableDefaultInteractivity(a);
                a.Interactions = [];
        end
    catch
        % Older releases, or an axes type that has no Interactions property: fall back to the
        % documented switch, and if even that is unavailable leave the axes alone rather than error.
        try, disableDefaultInteractivity(a); catch, end
    end
    % Deliberately does NOT touch Toolbar.Visible: several axes turn it on on purpose (the track
    % player wants its export/zoom buttons), and that is a display choice, not a safety one.
end
end

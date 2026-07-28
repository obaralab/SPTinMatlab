function Label_CS_DensityPlot_intUse(TrackStruct,CSstruct,HighlightIndex)

% Note: CS struct should NOT have CSs that you don't want labeled!!
% Note: This may need updated if CSindex no longer has the relevant indexes
% (e.g. CS_index exists)

if nargin==2
    InputIndex=[];
else
    Indexes=cell2mat({CSstruct.CSindex});
    [~,InputIndex]=ismember(HighlightIndex,Indexes);
end

if size(TrackStruct,2)~=1
    error('Put each cell in one at a time!')
end
DensityVisualization(TrackStruct,30); %Default is 30 nm pixels, change here if needed
hold on
SF=33.333; %Change the scale factor if you chagne the pixel size!

if ~isfield(CSstruct,'refCenter') %If the center hasn't been refined use the crude one
    for i=1:size(CSstruct,2)
        if CSstruct(i).MitoFlag==1
            scatter(CSstruct(i).center(1)*SF,CSstruct(i).center(2)*SF,[], 'r','filled');
            text(CSstruct(i).center(1)*SF+3,CSstruct(i).center(2)*SF+3,num2str(CSstruct(i).CSindex),'Color','red');
        else
            scatter(CSstruct(i).center(1)*SF,CSstruct(i).center(2)*SF,[], 'y','filled');
            text(CSstruct(i).center(1)*SF+3,CSstruct(i).center(2)*SF+3,num2str(CSstruct(i).CSindex),'Color','yellow');
        end
    end

    for i=1:numel(InputIndex)
        scatter(CSstruct(InputIndex(i)).center(1)*SF,CSstruct(InputIndex(i)).center(2)*SF,[], 'white','filled');
        text(CSstruct(InputIndex(i)).center(1)*SF+6,CSstruct(InputIndex(i)).center(2)*SF+6,num2str(HighlightIndex(i)),'Color','white','FontSize',20);
    end
elseif find(cellfun(@isempty,{CSstruct.refCenter})) %if some indexes of structure don't have refCenter, stick with normal one
    for i=1:size(CSstruct,2)
        if CSstruct(i).MitoFlag==1
            scatter(CSstruct(i).center(1)*SF,CSstruct(i).center(2)*SF,[], 'r','filled');
            text(CSstruct(i).center(1)*SF+3,CSstruct(i).center(2)*SF+3,num2str(CSstruct(i).CSindex),'Color','red');
        else
            scatter(CSstruct(i).center(1)*SF,CSstruct(i).center(2)*SF,[], 'y','filled');
            text(CSstruct(i).center(1)*SF+3,CSstruct(i).center(2)*SF+3,num2str(CSstruct(i).CSindex),'Color','yellow');
        end
    end

    for i=1:numel(InputIndex)
        scatter(CSstruct(InputIndex(i)).center(1)*SF,CSstruct(InputIndex(i)).center(2)*SF,[], 'white','filled');
        text(CSstruct(InputIndex(i)).center(1)*SF+6,CSstruct(InputIndex(i)).center(2)*SF+6,num2str(HighlightIndex(i)),'Color','white','FontSize',20);
    end
else % Hooray they all have a refCenter :-D
    for i=1:size(CSstruct,2)
        if CSstruct(i).MitoFlag==1
            scatter(CSstruct(i).refCenter(1)*SF,CSstruct(i).refCenter(2)*SF,[], 'r','filled');
            text(CSstruct(i).refCenter(1)*SF+3,CSstruct(i).refCenter(2)*SF+3,num2str(CSstruct(i).CSindex),'Color','red');
        else
            scatter(CSstruct(i).refCenter(1)*SF,CSstruct(i).refCenter(2)*SF,[], 'y','filled');
            text(CSstruct(i).refCenter(1)*SF+3,CSstruct(i).refCenter(2)*SF+3,num2str(CSstruct(i).CSindex),'Color','yellow');
        end
    end
    
    for i=1:numel(InputIndex)
        scatter(CSstruct(InputIndex(i)).refCenter(1)*SF,CSstruct(InputIndex(i)).refCenter(2)*SF,[], 'white','filled');
        text(CSstruct(InputIndex(i)).refCenter(1)*SF+6,CSstruct(InputIndex(i)).refCenter(2)*SF+6,num2str(HighlightIndex(i)),'Color','white','FontSize',20);
    end

end

end

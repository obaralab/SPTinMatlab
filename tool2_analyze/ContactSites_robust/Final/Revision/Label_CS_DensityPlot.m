
function Label_CS_DensityPlot(TrackStruct,CSstruct)

% Note: CS struct should NOT have CSs that you don't want labeled!!

if size(TrackStruct,2)~=1
    error('Put each cell in one at a time!')
end

DensityVisualization(TrackStruct,30); %Default is 30 nm pixels, change here if needed
hold on
SF=33.333; %Change the scale factor if you chagne the pixel size!

for i=1:size(CSstruct,2)
    scatter(CSstruct(i).refCenter(1)*SF,CSstruct(i).refCenter(2)*SF,[], 'r','filled');
    text(CSstruct(i).refCenter(1)*SF+3,CSstruct(i).refCenter(2)*SF+3,num2str(i),'Color','red');
end
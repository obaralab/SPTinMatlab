
function EMcurvStruct=EMtracer_2Dv1(EMdir)

if nargin==0
    EMdir=pwd;
end

 % Figure out who we can process
 Files=dir(fullfile(EMdir,'*.tif'));
 NumSlices=size(Files,1);
 files={Files.name}';

 EMcurvStruct=struct('file',[],'refPoint',[],'curve',[]);
 mkdir TempData

 for i=1:NumSlices
     % Load each image and figure out how big it is
     filename=char(files{i});
     imSlice=ChrisPrograms.loadtiff(fullfile(pwd,filename));
     SliceSize=size(imSlice);
        % Check that it didn't ignore the color dimension, if so, add it
        % back!
        if size(SliceSize,2)<3
            SliceSize=[SliceSize 1];
        end

     % Check that the image is in a format that makes sense, otherwise
     % error report
     if size(SliceSize,2)>3
         error(['The file ', filename, ' is a stack. Choose which slice to use.']);
     end

     if ~isa(imSlice,"uint8")
         uint8(imSlice);
         warning('Slice is not uint8. Converting--check for clipping artifacts!');
     end

     %Define where the EM data is in the image
     if SliceSize(3)>1
         % Check these are colors not slices
         NumVals=NaN(1,SliceSize(3));
         for j=1:SliceSize(3) 
            NumVals(j)=size(unique(imSlice(:,:,j)),1);
         end

         %I'm arbitrarily assuming you'd never have more than 20 labels
         %in a single label field image...if that's not true, adjust here:
         if nnz(NumVals>20)>1
           %  error('At least one channel besides the EM has too much dynamic range for labels.');
           EMchannel=2;
         else
             EMchannel=find(NumVals>20);
             disp(['The information density of the image ',filename,' is: ']);
             disp(NumVals);
             disp(['Choosing dimension ', num2str(EMchannel), ' as EM image.']);
             disp(' ');
         end
     else
         EMchannel=1;
     end

     figure;
     hold off
     imG=imresize(imSlice(:,:,EMchannel),5);
     imshow(imG,[min(imG,[],"all") max(imG,[],"all")],'Border','tight');
     set(gcf,'Position',[500 -650 500 500]);
     
     % As a convention, I'm defining the point to be inside the structure.
     % Just put it anywhere inside, but be consistent with which member of
     % the pair you are measuring or your signs wioll be reversed.
     roi1=drawpoint;
     hold on
     scatter(roi1.Position(1),roi1.Position(2),[],'k','filled');
     roi2=drawfreehand;

     EMcurvStruct(i).file=filename;
     EMcurvStruct(i).inside=roi1.Position;
     EMcurvStruct(i).curve=roi2.Position;
     A=EMcurvStruct(i);
     save(fullfile(EMdir,'TempData',strcat(filename(1:end-4),'.mat')),'A');

     close(gcf);
 end


        
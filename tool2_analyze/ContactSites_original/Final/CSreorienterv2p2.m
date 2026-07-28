
function CS2=CSreorienterv2p2(CS1)

for j=1:size(CS1,2)
    Pt1=(3/1000)*(CS1(j).Orientation.North-200);
    theta=rad2deg(angle(Pt1(1)+1i*Pt1(2)));
    
    CS2(j)=CoordShiftCS(CS1,j,-theta);
    
end

end
    




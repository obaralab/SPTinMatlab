function [Complete, Incomplete]=ParseCompleteInteractions(BindingTable)

        
         CompleteInd=find((table2array(BindingTable(:,4)).*table2array(BindingTable(:,5))));
        
         Complete=BindingTable(CompleteInd,:);
         IncompleteInd=ones(size(BindingTable,1),1);
         IncompleteInd(CompleteInd)=0;

         Incomplete=BindingTable(find(IncompleteInd),:);

end
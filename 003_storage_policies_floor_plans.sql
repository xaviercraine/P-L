-- Conversation 3: Storage policies for floor-plans bucket (authenticated upload)
CREATE POLICY storage_floor_plans_auth_read
ON storage.objects
FOR SELECT
TO authenticated
USING (bucket_id = 'floor-plans');

CREATE POLICY storage_floor_plans_staff_update
ON storage.objects
FOR UPDATE
TO authenticated
USING (bucket_id = 'floor-plans')
WITH CHECK (bucket_id = 'floor-plans');

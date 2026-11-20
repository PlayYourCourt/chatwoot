class AddStatusIndexToDataImportItems < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  # salesforce:report groups an import's items by type and status; on a million items that needs an index.
  def change
    add_index :data_import_items, [:data_import_id, :source_object_type, :status],
              name: 'idx_data_import_items_on_import_type_and_status', algorithm: :concurrently, if_not_exists: true
  end
end

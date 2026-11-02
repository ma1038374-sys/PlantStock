using System;
using System.Configuration;
using System.Data;
using System.Data.SqlClient;
using System.Drawing;
using System.Windows.Forms;

namespace PlantStock
{
    // ---------- Доступ к данным ----------
    public static class Db
    {
        private static readonly string ConnStr =
            ConfigurationManager.ConnectionStrings["PlantsDb"].ConnectionString;

        // Выборка данных (для DataGridView и списков)
        public static DataTable GetTable(string sql, params SqlParameter[] p)
        {
            var table = new DataTable();
            using (var conn = new SqlConnection(ConnStr))
            using (var cmd = new SqlCommand(sql, conn))
            {
                cmd.Parameters.AddRange(p);
                using (var adapter = new SqlDataAdapter(cmd))
                {
                    adapter.Fill(table);
                }
            }
            return table;
        }

        // Выполнение INSERT / UPDATE / DELETE
        public static int Execute(string sql, params SqlParameter[] p)
        {
            using (var conn = new SqlConnection(ConnStr))
            using (var cmd = new SqlCommand(sql, conn))
            {
                cmd.Parameters.AddRange(p);
                conn.Open();
                return cmd.ExecuteNonQuery();
            }
        }

        // Формирование заявки поставщику: вызов хранимой процедуры
        public static int CreateOrder(int supplierId)
        {
            using (var conn = new SqlConnection(ConnStr))
            using (var cmd = new SqlCommand("sp_CreateReplenishmentOrder", conn))
            {
                cmd.CommandType = CommandType.StoredProcedure;
                cmd.Parameters.AddWithValue("@supplier_id", supplierId);
                var orderId = new SqlParameter("@order_id", SqlDbType.Int)
                {
                    Direction = ParameterDirection.Output
                };
                cmd.Parameters.Add(orderId);
                conn.Open();
                cmd.ExecuteNonQuery();
                return (int)orderId.Value;
            }
        }
    }

    // ---------- Главная форма ----------
    public class MainForm : Form
    {
        private DataGridView dgvStock;
        private Button btnRefresh, btnToOrder, btnCreateOrder, btnAdd;
        private TextBox txtName, txtUnit;
        private ComboBox cmbCategory, cmbPlantSupplier, cmbOrderSupplier;
        private NumericUpDown numMin, numMax;

        public MainForm()
        {
            Text = "Пополнение растительных запасов — Станция юных натуралистов";
            Size = new Size(1000, 640);
            StartPosition = FormStartPosition.CenterScreen;

            // Верхняя панель с кнопками
            var top = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 44, Padding = new Padding(6) };
            btnRefresh = new Button { Text = "Остатки", Width = 100 };
            btnToOrder = new Button { Text = "К заказу", Width = 100 };
            cmbOrderSupplier = new ComboBox { Width = 200, DropDownStyle = ComboBoxStyle.DropDownList };
            btnCreateOrder = new Button { Text = "Создать заявку", Width = 130 };
            top.Controls.AddRange(new Control[] { btnRefresh, btnToOrder, cmbOrderSupplier, btnCreateOrder });

            // Таблица
            dgvStock = new DataGridView
            {
                Dock = DockStyle.Fill,
                ReadOnly = true,
                AllowUserToAddRows = false,
                AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill,
                SelectionMode = DataGridViewSelectionMode.FullRowSelect
            };

            // Нижняя панель: добавление растения
            var bottom = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 80, Padding = new Padding(6) };
            txtName = new TextBox { Width = 220 };
            cmbCategory = new ComboBox { Width = 160, DropDownStyle = ComboBoxStyle.DropDownList };
            txtUnit = new TextBox { Width = 50, Text = "шт." };
            numMin = new NumericUpDown { Width = 60, Maximum = 100000 };
            numMax = new NumericUpDown { Width = 60, Maximum = 100000 };
            cmbPlantSupplier = new ComboBox { Width = 180, DropDownStyle = ComboBoxStyle.DropDownList };
            btnAdd = new Button { Text = "Добавить растение", Width = 140 };
            bottom.Controls.AddRange(new Control[] {
                new Label { Text = "Название:", AutoSize = true, Margin = new Padding(3, 8, 0, 0) }, txtName,
                new Label { Text = "Категория:", AutoSize = true, Margin = new Padding(3, 8, 0, 0) }, cmbCategory,
                new Label { Text = "Ед.:", AutoSize = true, Margin = new Padding(3, 8, 0, 0) }, txtUnit,
                new Label { Text = "Min:", AutoSize = true, Margin = new Padding(3, 8, 0, 0) }, numMin,
                new Label { Text = "Max:", AutoSize = true, Margin = new Padding(3, 8, 0, 0) }, numMax,
                new Label { Text = "Поставщик:", AutoSize = true, Margin = new Padding(3, 8, 0, 0) }, cmbPlantSupplier,
                btnAdd });

            Controls.Add(dgvStock);
            Controls.Add(top);
            Controls.Add(bottom);

            btnRefresh.Click += (s, e) => LoadStock();
            btnToOrder.Click += (s, e) => LoadToOrder();
            btnCreateOrder.Click += btnCreateOrder_Click;
            btnAdd.Click += btnAdd_Click;
            Load += (s, e) => { LoadLists(); LoadStock(); };
        }

        // Загрузка справочников в выпадающие списки
        private void LoadLists()
        {
            try
            {
                BindCombo(cmbCategory, "SELECT category_id AS id, category_name AS name FROM plant_categories");
                BindCombo(cmbPlantSupplier, "SELECT supplier_id AS id, supplier_name AS name FROM suppliers");
                BindCombo(cmbOrderSupplier, "SELECT supplier_id AS id, supplier_name AS name FROM suppliers");
            }
            catch (Exception ex) { ShowError(ex); }
        }

        private static void BindCombo(ComboBox cmb, string sql)
        {
            cmb.DisplayMember = "name";
            cmb.ValueMember = "id";
            cmb.DataSource = Db.GetTable(sql);
        }

        // Текущие остатки (представление v_stock)
        private void LoadStock()
        {
            try
            {
                dgvStock.DataSource = Db.GetTable(
                    "SELECT plant_name AS [Растение], category_name AS [Категория], unit AS [Ед.], " +
                    "qty AS [Остаток], min_qty AS [Min], max_qty AS [Max], status AS [Статус] " +
                    "FROM v_stock ORDER BY plant_name");
            }
            catch (Exception ex) { ShowError(ex); }
        }

        // Растения к заказу (представление v_to_order)
        private void LoadToOrder()
        {
            try
            {
                dgvStock.DataSource = Db.GetTable(
                    "SELECT plant_name AS [Растение], unit AS [Ед.], qty AS [Остаток], " +
                    "min_qty AS [Min], max_qty AS [Max], recommended_qty AS [К заказу] " +
                    "FROM v_to_order ORDER BY plant_name");
            }
            catch (Exception ex) { ShowError(ex); }
        }

        private void btnCreateOrder_Click(object sender, EventArgs e)
        {
            if (cmbOrderSupplier.SelectedValue == null) return;
            try
            {
                int orderId = Db.CreateOrder((int)cmbOrderSupplier.SelectedValue);
                MessageBox.Show("Создана заявка № " + orderId, "Готово");
                LoadToOrder();
            }
            catch (Exception ex) { ShowError(ex); }
        }

        private void btnAdd_Click(object sender, EventArgs e)
        {
            // Валидация ввода
            if (string.IsNullOrWhiteSpace(txtName.Text))
            {
                MessageBox.Show("Введите название растения! Поле не должно быть пустым.", "Ошибка");
                return;
            }
            if (numMax.Value < numMin.Value)
            {
                MessageBox.Show("Max не может быть меньше Min.", "Ошибка");
                return;
            }
            try
            {
                // Параметризованный запрос защищает от SQL-инъекций
                Db.Execute(
                    "INSERT INTO plants (plant_name, category_id, unit, min_qty, max_qty, supplier_id) " +
                    "VALUES (@name, @cat, @unit, @min, @max, @sup)",
                    new SqlParameter("@name", txtName.Text.Trim()),
                    new SqlParameter("@cat", (int)cmbCategory.SelectedValue),
                    new SqlParameter("@unit", txtUnit.Text.Trim()),
                    new SqlParameter("@min", (int)numMin.Value),
                    new SqlParameter("@max", (int)numMax.Value),
                    new SqlParameter("@sup", (int)cmbPlantSupplier.SelectedValue));
                MessageBox.Show("Растение успешно добавлено в базу!", "Готово");
                txtName.Clear();
                LoadStock();
            }
            catch (Exception ex) { ShowError(ex); }
        }

        private static void ShowError(Exception ex)
        {
            MessageBox.Show(ex.Message, "Ошибка работы с базой данных",
                MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    static class Program
    {
        [STAThread]
        static void Main()
        {
            Application.EnableVisualStyles();
            Application.Run(new MainForm());
        }
    }
}

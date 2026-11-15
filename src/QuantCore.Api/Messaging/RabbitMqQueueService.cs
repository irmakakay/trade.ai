using System.Text;
using System.Text.Json;
using QuantCore.Contracts.Messaging;
using RabbitMQ.Client;

namespace QuantCore.Api.Messaging;

public interface IRabbitMqQueueService
{
    void SubmitTaskToInputQueue(InputTaskMessage task);
    OutputStatusMessage? PeekOutputQueueStatus();
}

public sealed class RabbitMqQueueService : IRabbitMqQueueService
{
    public const string InputQueueName = "input_queue";
    public const string OutputQueueName = "output_queue";
    private readonly IConnection _connection;

    public RabbitMqQueueService(IConnection connection)
    {
        _connection = connection;
        EnsureQueuesDeclared();
    }

    private void EnsureQueuesDeclared()
    {
        using var channel = _connection.CreateModel();
        channel.QueueDeclare(queue: InputQueueName, durable: true, exclusive: false, autoDelete: false, arguments: null);

        var outputArgs = new Dictionary<string, object>
        {
            ["x-max-length"] = 1,
            ["x-overflow"] = "drop-head"
        };
        channel.QueueDeclare(queue: OutputQueueName, durable: true, exclusive: false, autoDelete: false, arguments: outputArgs);
    }

    public void SubmitTaskToInputQueue(InputTaskMessage task)
    {
        using var channel = _connection.CreateModel();
        var props = channel.CreateBasicProperties();
        props.Persistent = true;

        var startStatus = new OutputStatusMessage(
            task.JobId,
            QueueJobState.STARTING,
            0m,
            0m,
            null,
            null,
            DateTimeOffset.UtcNow
        );

        var statusBytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(startStatus));
        channel.BasicPublish(exchange: "", routingKey: OutputQueueName, basicProperties: props, body: statusBytes);

        var taskBytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(task));
        channel.BasicPublish(exchange: "", routingKey: InputQueueName, basicProperties: props, body: taskBytes);
    }

    public OutputStatusMessage? PeekOutputQueueStatus()
    {
        using var channel = _connection.CreateModel();
        BasicGetResult? result = channel.BasicGet(queue: OutputQueueName, autoAck: false);
        if (result is null)
        {
            return null;
        }

        var json = Encoding.UTF8.GetString(result.Body.ToArray());
        var status = JsonSerializer.Deserialize<OutputStatusMessage>(json);

        if (status is not null && (status.Status == QueueJobState.SUCCEEDED || status.Status == QueueJobState.FAILED))
        {
            channel.BasicAck(result.DeliveryTag, multiple: false);
        }
        else
        {
            channel.BasicNack(result.DeliveryTag, multiple: false, requeue: true);
        }

        return status;
    }
}
